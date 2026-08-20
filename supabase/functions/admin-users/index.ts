import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// This function keeps only what genuinely needs the auth admin API: creating
// an account and setting a password. Role and activation used to be changed
// here as well, which meant two places could write profiles.role — this one
// with a service key and a self-only lockout check, and the capability-guarded
// update_user_profile RPC with the full one. Two writable authorities over the
// same money-adjacent field is the thing the migration is trying to end, so
// those fields now belong to the RPC alone and are refused here.
const PROFILE_FIELDS_MOVED_TO_RPC = ["role", "is_active", "full_name"];

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return reply({ error: "Method not allowed" }, 405);
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const bearer = req.headers.get("Authorization") || "";

  if (!bearer.startsWith("Bearer ")) {
    return reply({ error: "Unauthorized" }, 401);
  }

  const token = bearer.slice("Bearer ".length).trim();
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } =
    await admin.auth.getUser(token);

  if (userError || !userData.user) {
    return reply({ error: "Unauthorized" }, 401);
  }

  const { data: callerProfile, error: profileError } = await admin
    .from("profiles")
    .select("id, role, is_active")
    .eq("id", userData.user.id)
    .maybeSingle();

  if (
    profileError ||
    !callerProfile ||
    callerProfile.is_active !== true ||
    callerProfile.role !== "admin"
  ) {
    return reply({ error: "Admin access required" }, 403);
  }

  try {
    const body = await req.json();
    const action = body.action;

    if (action === "list") {
      const { data, error } = await admin
        .from("profiles")
        .select("id, full_name, email, role, is_active, created_at")
        .order("created_at", { ascending: false });

      if (error) throw error;
      return reply({ users: data || [] });
    }

    if (action === "create") {
      const full_name = String(body.full_name || "").trim();
      const email = String(body.email || "").trim().toLowerCase();
      const password = String(body.password || "");
      const role = String(body.role || "viewer");

      if (!full_name || !email || password.length < 8) {
        return reply({ error: "Invalid account data" }, 400);
      }

      // The role catalogue lives in role_templates. A copy of it here would
      // drift the day a role is added, and the drift would show up as an
      // account that cannot be created for no visible reason.
      const { data: template, error: templateError } = await admin
        .from("role_templates")
        .select("key")
        .eq("key", role)
        .eq("is_active", true)
        .maybeSingle();

      if (templateError) throw templateError;
      if (!template) return reply({ error: `Unknown role ${role}` }, 400);

      const { data: created, error: createError } =
        await admin.auth.admin.createUser({
          email,
          password,
          email_confirm: true,
          user_metadata: { full_name },
        });

      if (createError) throw createError;

      const { error: upsertError } = await admin.from("profiles").upsert({
        id: created.user.id,
        full_name,
        email,
        role,
        is_active: true,
      });

      if (upsertError) {
        await admin.auth.admin.deleteUser(created.user.id);
        throw upsertError;
      }

      const { error: auditError } = await admin.from("audit_logs").insert({
        actor_id: userData.user.id,
        action: "user.created",
        entity_type: "profile",
        entity_id: created.user.id,
        after_data: { role, is_active: true },
        request_id: crypto.randomUUID(),
      });

      if (auditError) {
        const { error: cleanupError } = await admin.auth.admin.deleteUser(
          created.user.id,
        );
        if (cleanupError) {
          console.error("User creation rollback failed", cleanupError);
        }
        throw auditError;
      }

      return reply(
        {
          user: {
            id: created.user.id,
            full_name,
            email,
            role,
            is_active: true,
          },
        },
        201,
      );
    }

    if (action === "update") {
      const id = String(body.id || "");

      if (!id) {
        return reply({ error: "User id is required" }, 400);
      }

      const { data: targetProfile, error: targetError } = await admin
        .from("profiles")
        .select("id, full_name, email, role, is_active")
        .eq("id", id)
        .maybeSingle();

      if (targetError) throw targetError;
      if (!targetProfile) return reply({ error: "User not found" }, 404);

      const movedFields = PROFILE_FIELDS_MOVED_TO_RPC.filter(
        (field) => body[field] !== undefined,
      );

      if (movedFields.length > 0) {
        return reply(
          {
            error:
              `Changing ${movedFields.join(", ")} moved to the ` +
              `update_user_profile RPC, which requires the permission.manage ` +
              `capability, a stated reason, and passes the full lockout guard.`,
          },
          400,
        );
      }

      const hasPasswordChange = body.password !== undefined;

      if (!hasPasswordChange) {
        return reply({ error: "Nothing to update" }, 400);
      }

      if (String(body.password).length < 8) {
        return reply(
          { error: "Password must be at least 8 characters" },
          400,
        );
      }

      {
        const password = String(body.password);

        const { error: requestAuditError } = await admin
          .from("audit_logs")
          .insert({
            actor_id: userData.user.id,
            action: "user.password.update.requested",
            entity_type: "profile",
            entity_id: id,
            before_data: { password_changed: false },
            after_data: { password_change_requested: true },
            request_id: crypto.randomUUID(),
          });

        if (requestAuditError) throw requestAuditError;

        const { error } = await admin.auth.admin.updateUserById(id, {
          password,
        });

        if (error) throw error;

        const { error: auditError } = await admin.from("audit_logs").insert({
          actor_id: userData.user.id,
          action: "user.password.updated",
          entity_type: "profile",
          entity_id: id,
          before_data: { password_changed: false },
          after_data: { password_changed: true },
          request_id: crypto.randomUUID(),
        });

        if (auditError) console.error("Password completion audit failed", auditError);
      }

      return reply({ ok: true });
    }

    return reply({ error: "Unknown action" }, 400);
  } catch (error) {
    console.error(error);

    return reply(
      { error: error instanceof Error ? error.message : "Server error" },
      500,
    );
  }
});
