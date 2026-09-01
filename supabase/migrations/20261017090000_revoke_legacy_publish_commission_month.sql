-- إغلاق ثغرة API مباشرة: publish_commission_month لا تُستدعى من أي كود حيّ.
--
-- التحقق: grep شامل عبر index.html وassets/ وsrc/ لا يجد أي استدعاء
-- rpc/publish_commission_month. اختبار tests/babil-flow-ui.test.js يثبت هذا
-- أصلاً للشاشات السابقة (قائمة WRITES تتضمن الاسم وتفشل لو ظهر في الـHTML).
-- محرك الشهر المركزي القديم تقاعد لصالح دورات العمولة (commission cycles)،
-- وبقي فقط toast تنبيهي دون نداء فعلي. الدالة نفسها ما زالت ممنوحة لأي
-- authenticated عبر Supabase REST مباشرة، بمعزل عن الواجهة — مسار API لم
-- يُغلق رغم تقاعد المسار الوحيد الذي كان يستخدمه.
--
-- هذا لا يغيّر منطق tier_basis_qty ولا يحاول إصلاح الثقة بالمدخل من
-- المتصفح (تلك مسألة محكومة بقرار COM-009 غير المحسوم، وموثّقة في
-- tests/commission-tier-trust-boundary.test.js). هذا فقط يمنع استدعاء
-- الدالة كلياً من الآن فصاعداً — إغلاق تعرّض، لا إصلاح منطق.

begin;

revoke execute on function public.publish_commission_month(text, jsonb, jsonb, uuid)
  from authenticated, public, anon;

commit;
