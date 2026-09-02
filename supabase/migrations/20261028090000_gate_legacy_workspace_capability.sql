-- تدقيق QA ما بعد الإطلاق (2026-09-01، طلب #7): «مساحة العمل الكاملة»
-- (#/legacy) كانت بلا حقل capability إطلاقاً — لا في عنصر الشريط الجانبي
-- (src/app/shell.ts) ولا في تعريف المسار نفسه (src/main.ts). عنصر الشريط
-- بلا capability يُعرض للجميع (`!i.capability || can(i.capability)`،
-- shell.ts:136)، والمسار بلا capability يُصرَّح له الموجِّه بلا فحصٍ
-- (router.ts:178). فكل مستخدمٍ مسجَّلٍ دخوله، أياً كان دوره، كان يرى الرابط
-- ويفتح المساحة القديمة كاملةً — شاشات تشخيصٍ وأدواتٍ إداريةٍ لم تُصمَّم لغير
-- المدير.
--
-- الإصلاح: قدرة جديدة legacy.workspace، تُمنح لقالب admin وحده (لا تُدرَج في
-- القائمة المشتركة لـaccountant/monitor/viewer في 20260820090000) — فتُقرأ
-- حيّةً عبر effective_permission() دون أي تعديلٍ على تلك الهجرة المطبَّقة
-- أصلاً. الإصلاح المقابل على الواجهة (shell.ts، main.ts) في PR منفصل من نفس
-- حزمة الإصلاح.

begin;

insert into public.permission_capabilities (key, domain, label_ar, is_sensitive, is_self_protecting, scopeable)
values ('legacy.workspace', 'admin', 'مساحة العمل الكاملة (القديمة)', true, false, false)
on conflict (key) do nothing;

insert into public.role_template_capabilities (role_key, capability_key)
values ('admin', 'legacy.workspace')
on conflict do nothing;

commit;
