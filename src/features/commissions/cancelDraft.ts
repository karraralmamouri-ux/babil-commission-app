/**
 * إلغاء مسوّدةٍ فُتحت سهواً.
 *
 * الإلغاء ليس حذفاً. الحذف يمحو أنّ أحداً فتحها ومتى، والمسوّدة المفتوحة سهواً
 * واقعةٌ حصلت فعلاً — تُبطَل ولا تُنكَر. فالصفّ يبقى بحالة `CANCELLED`، وسجلّ
 * فتحه يبقى، ويُضاف إليه سجلّ إلغائه بمن ألغاه ومتى ولماذا.
 *
 * وهذا الملف بلا استيرادات عمداً: قواعده تُختبَر وحدها دون DOM ولا شبكة.
 */

/**
 * متى يظهر الإجراء.
 *
 * قاعدةٌ واحدة يقرؤها الزرّ والاختبار معاً، فلا تُكتب مرّتين وتفترقان.
 * والظهور راحةٌ لا حراسة: `cancel_empty_commission_cycle` تُعيد فحص القدرة
 * والحالة في كل نداء مهما أظهرت الشاشة.
 */
export function canCancelDraft(status: string, capable: boolean): boolean {
  return capable && status === 'DRAFT';
}

export interface CancelMessage {
  title: string;
  detail: string;
}

/** الجداول التي يعُدّها الخادم قبل أن يقبل الإلغاء، بأسمائها كما تُقرأ. */
const ROW_LABELS: ReadonlyArray<readonly [string, string]> = [
  ['entitlements', 'استحقاقات'],
  ['exceptions', 'استثناءات'],
  ['snapshots', 'لقطات'],
  ['batches', 'دفعات صرف'],
  ['corrections', 'تصحيحات'],
];

/**
 * يُسمّي ما تحمله الدورة فعلاً.
 *
 * الخادم يردّ الأعداد الخمسة كلّها ولو كانت أصفاراً، والمفيد منها ما ليس صفراً:
 * «تحتوي استحقاقات: 3» تقول للمستخدم أين يذهب، و«الأعداد 3 و0 و0 و0 و0» لا تقول.
 */
function carriedRows(raw: string): string {
  const parts: string[] = [];
  for (const [key, label] of ROW_LABELS) {
    const found = new RegExp(`${key}\\s+(\\d+)`).exec(raw);
    const n = found ? Number(found[1]) : 0;
    if (n > 0) parts.push(`${label}: ${n}`);
  }
  return parts.join(' · ');
}

/**
 * رسالة الخادم تُترجَم إلى ما يفعله المستخدم، لا إلى ما اشتكت منه القاعدة.
 *
 * `42501` و`P0002` رموزٌ للمهندس. والمستخدم يحتاج أن يعرف: ما الذي منع، وهل
 * يستطيع رفعه. فيبقى النصّ الخام للـconsole، ويُعرض هنا سببٌ تشغيليّ.
 */
export function cancelDraftError(raw: string): CancelMessage {
  const text = String(raw || '');

  if (/Capability .* is required|permission denied/i.test(text)) {
    return {
      title: 'لا صلاحية لإلغاء الدورات',
      detail: 'الإلغاء يحتاج قدرة commission.manage_cycle. راجع مدير النظام.',
    };
  }

  if (text.includes('Only a DRAFT cycle can be cancelled')) {
    const found = /this one is (\w+)/.exec(text);
    const status = found ? found[1] : '';
    return {
      title: 'هذه الدورة ليست مسوّدة',
      detail: `لا تُلغى إلا المسوّدة${status ? ` — وحالة هذه ${status}` : ''}.`
        + ' الدورة التي دخلت المراجعة أو اعتُمدت أو دُفعت لها مسارها الخاص، ولا تُلغى من هنا.',
    };
  }

  if (text.includes('has a calculated result')) {
    return {
      title: 'المسوّدة ليست فارغة',
      detail: 'شُغِّل حساب هذه المسوّدة، فصار لها نتيجة. الإلغاء لمن لم يُحسب لها شيء.',
    };
  }

  if (text.includes('carries business rows')) {
    const rows = carriedRows(text);
    return {
      title: 'الدورة تحمل بيانات عمل',
      detail: rows
        ? `لا تُلغى وفيها ${rows}. تُعالَج هذه أوّلاً في شاشاتها.`
        : 'لا تُلغى دورةٌ تحمل بيانات عمل. تُعالَج أوّلاً في شاشاتها.',
    };
  }

  if (text.includes('needs a reason')) {
    return {
      title: 'السبب إلزامي',
      detail: 'يُقرأ لاحقاً في سجلّ التدقيق: لماذا أُلغيت هذه المسوّدة.',
    };
  }

  if (text.includes('request_id is required')) {
    return {
      title: 'تعذّر إرسال الطلب',
      detail: 'نقص معرّف الطلب الذي يمنع تكرار التنفيذ. أعد المحاولة.',
    };
  }

  if (text.includes('was not found')) {
    return {
      title: 'الدورة غير موجودة',
      detail: 'ربما أُلغيت أو حُذفت من جلسةٍ أخرى. حدِّث قائمة الدورات.',
    };
  }

  return {
    title: 'لم يتم إلغاء المسودة',
    detail: 'لم تتغيّر الدورة. أعد المحاولة، وإن تكرّر فراجع سجلّ الأخطاء.',
  };
}

/** نجاحٌ أوّل أم طلبٌ وصل مرّتين — الفرق يُقال للمستخدم صراحةً. */
export function cancelDraftSuccess(replayed: boolean): CancelMessage {
  return replayed
    ? {
      title: 'المسودة ملغاة أصلاً',
      detail: 'وصل الطلب مرّتين ونُفِّذ مرّةً واحدة، فلا أثر مزدوج في السجلّ.',
    }
    : {
      title: 'تم إلغاء المسودة وحفظ العملية في سجل التدقيق',
      detail: 'الدورة محفوظة بحالة «ملغاة»، وتاريخ إنشائها باقٍ كما هو.',
    };
}
