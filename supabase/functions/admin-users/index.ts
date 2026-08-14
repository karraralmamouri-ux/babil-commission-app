import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const roles = new Set(["admin", "accountant", "monitor", "viewer"]);

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

      if (!full_name || !email || password.length < 8 || !roles.has(role)) {
        return reply({ error: "Invalid account data" }, 400);
      }

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

      const profilePatch: Record<string, unknown> = {};

      if (body.role !== undefined) {
        const role = String(body.role);

        if (!roles.has(role)) {
          return reply({ error: "Invalid role" }, 400);
        }

        profilePatch.role = role;
      }

      if (body.is_active !== undefined) {
        profilePatch.is_active = Boolean(body.is_active);
      }

      const hasProfileChange = Object.keys(profilePatch).length > 0;
      const hasPasswordChange = body.password !== undefined;

      if (hasProfileChange && hasPasswordChange) {
        return reply(
          { error: "Profile and password changes must be separate requests" },
          400,
        );
      }

      if (hasPasswordChange && String(body.password).length < 8) {
        return reply(
          { error: "Password must be at least 8 characters" },
          400,
        );
      }

      if (
        id === userData.user.id &&
        (profilePatch.is_active === false ||
          (profilePatch.role !== undefined &&
            profilePatch.role !== "admin"))
      ) {
        return reply(
          { error: "You cannot remove your own admin access" },
          400,
        );
      }

      if (hasProfileChange) {
        const { data: updatedProfile, error } = await admin
          .from("profiles")
          .update(profilePatch)
          .eq("id", id)
          .select("id, full_name, email, role, is_active")
          .single();

        if (error) throw error;

        const { error: auditError } = await admin.from("audit_logs").insert({
          actor_id: userData.user.id,
          action: "user.permissions.updated",
          entity_type: "profile",
          entity_id: id,
          before_data: {
            role: targetProfile.role,
            is_active: targetProfile.is_active,
          },
          after_data: {
            role: updatedProfile.role,
            is_active: updatedProfile.is_active,
          },
          request_id: crypto.randomUUID(),
        });

        if (auditError) {
          const { error: rollbackError } = await admin
            .from("profiles")
            .update({
              role: targetProfile.role,
              is_active: targetProfile.is_active,
            })
            .eq("id", id);

          if (rollbackError) {
            console.error("User update rollback failed", rollbackError);
          }
          throw auditError;
        }
      }

      if (hasPasswordChange) {
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
