import { createClient } from "npm:@supabase/supabase-js@2";

/* =========================================================
   CORS
========================================================= */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods":
    "POST, OPTIONS",
};

/* =========================================================
   RESPONSE
========================================================= */

function jsonResponse(
  data: Record<string, unknown>,
  status = 200
): Response {
  return new Response(
    JSON.stringify(data),
    {
      status,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
      },
    }
  );
}

/* =========================================================
   GET SECRET KEY
========================================================= */

function getSecretKey(): string | null {
  /*
    Supabase الجديد يوفر:
    SUPABASE_SECRET_KEYS

    وهو JSON يحتوي على مفاتيح Secret.
  */

  const secretKeys = Deno.env.get(
    "SUPABASE_SECRET_KEYS"
  );

  if (secretKeys) {
    try {
      const parsed = JSON.parse(secretKeys);

      /*
        نحاول استخراج أول secret key
        من JSON مهما كان اسم الخاصية.
      */

      if (typeof parsed === "string") {
        return parsed;
      }

      if (
        parsed &&
        typeof parsed === "object"
      ) {
        for (const value of Object.values(parsed)) {
          if (
            typeof value === "string" &&
            value.startsWith("sb_secret_")
          ) {
            return value;
          }
        }
      }
    } catch (error) {
      console.error(
        "Failed to parse SUPABASE_SECRET_KEYS:",
        error
      );
    }
  }

  /*
    احتياطاً إذا كان عندك Secret مضاف يدوياً
    باسم SUPABASE_SECRET_KEY
  */

  const directSecret =
    Deno.env.get("SUPABASE_SECRET_KEY");

  if (directSecret) {
    return directSecret;
  }

  /*
    دعم قديم إذا كان موجوداً
  */

  const serviceRole =
    Deno.env.get(
      "SUPABASE_SERVICE_ROLE_KEY"
    );

  if (serviceRole) {
    return serviceRole;
  }

  return null;
}

/* =========================================================
   MAIN FUNCTION
========================================================= */

Deno.serve(async (req: Request) => {
  /* =======================================================
     OPTIONS
  ======================================================= */

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      status: 200,
      headers: corsHeaders,
    });
  }

  /* =======================================================
     POST ONLY
  ======================================================= */

  if (req.method !== "POST") {
    return jsonResponse(
      {
        success: false,
        error:
          "Only POST requests are allowed",
      },
      405
    );
  }

  try {
    /* =====================================================
       ENVIRONMENT
    ===================================================== */

    const supabaseUrl =
      Deno.env.get("SUPABASE_URL");

    if (!supabaseUrl) {
      console.error(
        "SUPABASE_URL is missing"
      );

      return jsonResponse(
        {
          success: false,
          error:
            "SUPABASE_URL غير موجود في Secrets",
        },
        500
      );
    }

    /* =====================================================
       PUBLISHABLE KEY
    ===================================================== */

    let publishableKey =
      Deno.env.get(
        "SUPABASE_PUBLISHABLE_KEY"
      );

    /*
      Supabase الجديد قد يوفر:
      SUPABASE_PUBLISHABLE_KEYS
    */

    if (!publishableKey) {
      const publishableKeys =
        Deno.env.get(
          "SUPABASE_PUBLISHABLE_KEYS"
        );

      if (publishableKeys) {
        try {
          const parsed =
            JSON.parse(
              publishableKeys
            );

          if (
            typeof parsed === "string"
          ) {
            publishableKey = parsed;
          } else if (
            parsed &&
            typeof parsed === "object"
          ) {
            for (
              const value of Object.values(
                parsed
              )
            ) {
              if (
                typeof value === "string" &&
                value.startsWith(
                  "sb_publishable_"
                )
              ) {
                publishableKey = value;
                break;
              }
            }
          }
        } catch (error) {
          console.error(
            "Publishable keys parse error:",
            error
          );
        }
      }
    }

    if (!publishableKey) {
      return jsonResponse(
        {
          success: false,
          error:
            "SUPABASE_PUBLISHABLE_KEY غير موجود",
        },
        500
      );
    }

    /* =====================================================
       SECRET KEY
    ===================================================== */

    const secretKey =
      getSecretKey();

    if (!secretKey) {
      console.error(
        "No Supabase secret key found"
      );

      return jsonResponse(
        {
          success: false,
          error:
            "لم يتم العثور على Supabase Secret Key",
        },
        500
      );
    }

    /* =====================================================
       AUTHORIZATION HEADER
    ===================================================== */

    const authHeader =
      req.headers.get(
        "Authorization"
      );

    if (!authHeader) {
      return jsonResponse(
        {
          success: false,
          error:
            "يجب تسجيل الدخول أولاً",
        },
        401
      );
    }

    const token =
      authHeader
        .replace(
          /^Bearer\s+/i,
          ""
        )
        .trim();

    if (!token) {
      return jsonResponse(
        {
          success: false,
          error:
            "جلسة الدخول غير صالحة",
        },
        401
      );
    }

    /* =====================================================
       USER CLIENT
    ===================================================== */

    const userClient =
      createClient(
        supabaseUrl,
        publishableKey,
        {
          auth: {
            autoRefreshToken: false,
            persistSession: false,
          },
        }
      );

    /* =====================================================
       CHECK CURRENT USER
    ===================================================== */

    const {
      data: userData,
      error: userError,
    } =
      await userClient.auth.getUser(
        token
      );

    if (
      userError ||
      !userData.user
    ) {
      console.error(
        "AUTH USER ERROR:",
        userError
      );

      return jsonResponse(
        {
          success: false,
          error:
            "جلسة الدخول غير صالحة أو انتهت",
        },
        401
      );
    }

    const currentUser =
      userData.user;

    console.log(
      "Current user:",
      currentUser.id
    );

    /* =====================================================
       ADMIN CLIENT
    ===================================================== */

    const adminClient =
      createClient(
        supabaseUrl,
        secretKey,
        {
          auth: {
            autoRefreshToken: false,
            persistSession: false,
          },
        }
      );

    /* =====================================================
       GET CURRENT PROFILE
    ===================================================== */

    const {
      data: currentProfile,
      error:
        currentProfileError,
    } =
      await adminClient
        .from("profiles")
        .select(
          "id, full_name, email, role, is_active"
        )
        .eq(
          "id",
          currentUser.id
        )
        .maybeSingle();

    if (
      currentProfileError
    ) {
      console.error(
        "PROFILE CHECK ERROR:",
        currentProfileError
      );

      return jsonResponse(
        {
          success: false,
          error:
            "خطأ في قراءة Profile: " +
            currentProfileError.message,
        },
        500
      );
    }

    if (!currentProfile) {
      return jsonResponse(
        {
          success: false,
          error:
            "لم يتم العثور على Profile الخاص بحسابك",
        },
        403
      );
    }

    /* =====================================================
       ADMIN PERMISSION
    ===================================================== */

    if (
      currentProfile.role !==
      "admin"
    ) {
      return jsonResponse(
        {
          success: false,
          error:
            "ليس لديك صلاحية لإنشاء المستخدمين",
        },
        403
      );
    }

    /* =====================================================
       ACTIVE CHECK
    ===================================================== */

    if (
      currentProfile.is_active !==
      true
    ) {
      return jsonResponse(
        {
          success: false,
          error:
            "حساب Admin غير فعال",
        },
        403
      );
    }

    /* =====================================================
       READ BODY
    ===================================================== */

    let body:
      | Record<string, unknown>
      | null = null;

    try {
      body = await req.json();
    } catch (error) {
      console.error(
        "JSON BODY ERROR:",
        error
      );

      return jsonResponse(
        {
          success: false,
          error:
            "بيانات الطلب غير صحيحة",
        },
        400
      );
    }

    /* =====================================================
       INPUTS
    ===================================================== */

    const fullName =
      String(
        body?.full_name ?? ""
      ).trim();

    const email =
      String(
        body?.email ?? ""
      )
        .trim()
        .toLowerCase();

    const password =
      String(
        body?.password ?? ""
      );

    const role =
      String(
        body?.role ?? "viewer"
      ).trim();

    /* =====================================================
       ALLOWED ROLES
    ===================================================== */

    const allowedRoles = [
      "admin",
      "accountant",
      "monitor",
      "follower",
      "viewer",
    ];

    /* =====================================================
       VALIDATION
    ===================================================== */

    if (!fullName) {
      return jsonResponse(
        {
          success: false,
          error:
            "الاسم الكامل مطلوب",
        },
        400
      );
    }

    if (!email) {
      return jsonResponse(
        {
          success: false,
          error:
            "البريد الإلكتروني مطلوب",
        },
        400
      );
    }

    const emailRegex =
      /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

    if (
      !emailRegex.test(email)
    ) {
      return jsonResponse(
        {
          success: false,
          error:
            "البريد الإلكتروني غير صحيح",
        },
        400
      );
    }

    if (
      password.length < 8
    ) {
      return jsonResponse(
        {
          success: false,
          error:
            "كلمة المرور يجب أن تكون 8 أحرف على الأقل",
        },
        400
      );
    }

    if (
      !allowedRoles.includes(
        role
      )
    ) {
      return jsonResponse(
        {
          success: false,
          error:
            "الصلاحية المحددة غير صحيحة",
        },
        400
      );
    }

    /* =====================================================
       CREATE AUTH USER
    ===================================================== */

    console.log(
      "Creating Auth user:",
      email
    );

    const {
      data:
        createdUserData,
      error:
        createUserError,
    } =
      await adminClient.auth.admin.createUser(
        {
          email,
          password,
          email_confirm: true,
          user_metadata: {
            full_name:
              fullName,
          },
        }
      );

    if (
      createUserError
    ) {
      console.error(
        "CREATE AUTH USER ERROR:",
        createUserError
      );

      return jsonResponse(
        {
          success: false,
          error:
            createUserError.message,
        },
        400
      );
    }

    if (
      !createdUserData.user
    ) {
      return jsonResponse(
        {
          success: false,
          error:
            "فشل إنشاء المستخدم",
        },
        500
      );
    }

    const newUser =
      createdUserData.user;

    console.log(
      "Auth user created:",
      newUser.id
    );

    /* =====================================================
       CREATE / UPDATE PROFILE
    ===================================================== */

    /*
      نستخدم upsert بدل insert
      حتى إذا عندك Database Trigger
      ينشئ Profile تلقائياً،
      ما يصير duplicate error.
    */

    const {
      error:
        profileError,
    } =
      await adminClient
        .from("profiles")
        .upsert(
          {
            id: newUser.id,
            full_name:
              fullName,
            email,
            role,
            is_active:
              true,
          },
          {
            onConflict: "id",
          }
        );

    /* =====================================================
       PROFILE ERROR
    ===================================================== */

    if (profileError) {
      console.error(
        "PROFILE UPSERT ERROR:",
        profileError
      );

      /* Rollback Auth user */

      try {
        await adminClient.auth.admin.deleteUser(
          newUser.id
        );
      } catch (deleteError) {
        console.error(
          "ROLLBACK ERROR:",
          deleteError
        );
      }

      return jsonResponse(
        {
          success: false,
          error:
            "تم إنشاء حساب Auth لكن فشل إنشاء Profile: " +
            profileError.message,
        },
        400
      );
    }

    /* =====================================================
       SUCCESS
    ===================================================== */

    console.log(
      "USER CREATED SUCCESSFULLY:",
      newUser.id
    );

    return jsonResponse(
      {
        success: true,
        message:
          "تم إنشاء المستخدم بنجاح",
        user: {
          id: newUser.id,
          email,
          full_name:
            fullName,
          role,
          is_active:
            true,
        },
      },
      200
    );
  } catch (error) {
    /* =====================================================
       GLOBAL ERROR
    ===================================================== */

    console.error(
      "ADMIN CREATE USER FATAL ERROR:",
      error
    );

    return jsonResponse(
      {
        success: false,
        error:
          error instanceof Error
            ? error.message
            : String(error),
      },
      500
    );
  }
});