/*!
 * قراءة ملفات SaaS الخام: مستخدمون وأحداث تفعيل.
 *
 * ثلاثة مبادئ تحكم هذا الملف:
 *   • ct_password يُسقَط عند التحليل. لا يُخزَّن ولا يُشفَّر ولا يُسجَّل.
 *   • إزالة التكرار على مستوى الحدث لا المشترك. الملفات الحقيقية تحمل
 *     8517 حدثاً إضافياً في تموز لمشتركين مكرّرين — إزالتها بالمشترك تُسقط 29%.
 *   • الغموض يبقى غموضاً: عمود مجهول يُهمَل، وطوبولوجيا مشكوكة تبقى فارغة،
 *     واكتمال غير مُثبت يبقى UNKNOWN.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.SaasImport = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // العمود السرّي. يُطابَق ويُسقَط قبل أي شيء آخر.
  const FORBIDDEN_COLUMNS = new Set(['ct_password', 'ctpassword', 'password', 'ct_pass']);

  // خريطة صريحة. الرؤوس التالفة مرصودة في ملف أيار الحقيقي، والمطابقة
  // التقريبية مرفوضة عمداً: proile_name وprofile_name يفرقان بحرف واحد،
  // ومطابق متساهل قد يربط العمود الخطأ بالثقة نفسها.
  const HEADER_ALIASES = new Map(Object.entries({
    id: 'id',
    username: 'username',
    firstname: 'firstname', irstname: 'firstname',
    lastname: 'lastname', lastnam: 'lastname', tnam: 'lastname',
    profile_name: 'profile_name', proile_name: 'profile_name',
    manager_firstname: 'manager_firstname', manager_irstname: 'manager_firstname',
    manager_lastname: 'manager_lastname', manager_lastnam: 'manager_lastname',
    parent: 'parent', parent_name: 'parent',
    created_at: 'created_at', last_online: 'last_online',
    expiration: 'expiration', old_expiration: 'old_expiration',
    new_expiration: 'new_expiration',
    activations_count: 'activations_count',
    transaction_id: 'transaction_id',
    canceled: 'canceled', cancelled: 'canceled',
    price: 'price', user_price: 'user_price', total_price: 'total_price',
    tax_amount: 'tax_amount', tax_rate: 'tax_rate',
    enabled: 'enabled', balance: 'balance',
    contract_id: 'contract_id', company: 'company',
    // ملف أيار يكتبه group وملف المستخدمين group_name. مرادف صريح مرصود.
    group_name: 'group_name', group: 'group_name',
    national_id: 'national_id', phone: 'phone', email: 'email',
    card: 'card', card_owner: 'card_owner', comment: 'comment', notes: 'notes',
    city: 'city', address: 'address', street: 'street',
    mac: 'mac', static_ip: 'static_ip',
    gps_lat: 'gps_lat', gps_lng: 'gps_lng',
  }));

  // عقدان منفصلان. ملف المستخدمين لا يحمل activations_count ولا parent،
  // فلو استُعمل عقد واحد لرُفض أو قُبل الملف الخطأ.
  const EVENT_CONTRACT = ['id', 'username', 'created_at', 'activations_count', 'parent'];
  const USER_CONTRACT = ['id', 'username', 'profile_name', 'parent'];

  function normalizeHeader(header) {
    return String(header == null ? '' : header).trim().toLowerCase().replace(/\s+/g, '_');
  }

  function canonicalField(header) {
    const key = normalizeHeader(header);
    if (FORBIDDEN_COLUMNS.has(key)) return null;
    return HEADER_ALIASES.get(key) || null;
  }

  /** يبني خريطة العمود الأصلي إلى الحقل القانوني، ويُبلغ عن الأعمدة المُسقطة. */
  function mapHeaders(headers) {
    const mapping = new Map();
    const dropped = [];
    // عدد فقط. حتى اسم العمود السرّي لا يُنقَل في تقرير أو بيانات وصفية.
    let secretsDropped = 0;
    (headers || []).forEach((header) => {
      const key = normalizeHeader(header);
      if (FORBIDDEN_COLUMNS.has(key)) { secretsDropped += 1; return; }
      const field = HEADER_ALIASES.get(key);
      if (!field) { dropped.push(header); return; }
      // أول عمود يفوز: لو حمل الملف profile_name وproile_name معاً، السليم أولاً.
      if (!mapping.has(field)) mapping.set(field, header);
    });
    return { mapping, dropped, secretsDropped };
  }

  function classifySheet(headers) {
    const { mapping } = mapHeaders(headers);
    const present = (list) => list.every((field) => mapping.has(field));
    if (present(EVENT_CONTRACT)) return 'ACTIVATION_EVENTS';
    if (present(USER_CONTRACT)) return 'USERS_SNAPSHOT';
    return 'REJECTED';
  }

  const text = (value) => {
    if (value === null || value === undefined) return null;
    const out = String(value).trim();
    return out === '' ? null : out;
  };

  function integer(value) {
    const raw = text(value);
    if (raw === null) return null;
    const n = Number(raw.replace(/[, ]/g, ''));
    return Number.isFinite(n) ? Math.trunc(n) : null;
  }

  function decimal(value) {
    const raw = text(value);
    if (raw === null) return null;
    const n = Number(raw.replace(/[, ]/g, ''));
    return Number.isFinite(n) ? n : null;
  }

  function bool(value) {
    const raw = text(value);
    if (raw === null) return null;
    const key = raw.toLowerCase();
    if (['1', 'true', 'yes', 'y', 'نعم'].includes(key)) return true;
    if (['0', 'false', 'no', 'n', 'لا'].includes(key)) return false;
    return null;
  }

  // صيغة مرصودة في تصديرين حقيقيين: الوقت بلا نقطتين — "2026-04-30 235650".
  // Date ترفضها، فكان كل حدث في ملفَي نيسان والغرامات يخرج بتاريخ فارغ (100%).
  // وحدثٌ بلا تاريخ لا يقع في أي نافذة دورة، فيُستبعد من كل حساب بلا استثناء
  // يُعلنه — أي صفرٌ صامت بدل خطأ ظاهر. لذلك تُقرأ الصيغة صراحةً.
  const COMPACT_TIME = /^(\d{4}-\d{2}-\d{2})[ T](\d{2})(\d{2})(\d{2})$/;

  // الطابع الزمني في التصدير بلا منطقة زمنية، وقراءتُه بالتوقيت المحلي للجهاز
  // تجعل الملف الواحد يُنتج لحظات UTC مختلفة باختلاف من استورده — وحدثٌ قرب
  // حدّ الشهر قد يقع عندها في دورة أخرى. لذلك تُثبَّت المنطقة صراحةً.
  //
  // و+03:00 ليست اختياراً: بيانات تموز في الإنتاج مخزَّنة بها فعلاً (أقصى حدث
  // 2026-07-31T20:58:30Z أي 23:58:30 بتوقيت بغداد)، وبغداد بلا توقيت صيفي منذ
  // 2015. فتثبيتها يطابق المخزَّن ويمنع اختلاف النتيجة بين جهاز وآخر.
  const SOURCE_UTC_OFFSET = '+03:00';
  const HAS_ZONE = /(?:Z|[+-]\d{2}:?\d{2})$/i;

  // خليّة التاريخ في Excel تصل كائنَ Date لأن القراءة تجري بـcellDates:true،
  // وSheetJS يبنيه بساعة الحائط في منطقة الجهاز. فـtoISOString تُعيد إسقاطه
  // بإزاحة الجهاز — وهو بعينه الاعتماد الذي أُلغي أعلاه في فرع النص. تُقرأ
  // المكوّنات كما كُتبت في الملف ثم تُنسَب إلى منطقة المصدر، فيخرج الملف
  // الواحد باللحظة نفسها من أي جهاز استُورد.
  function wallClock(value) {
    const p = (n) => String(n).padStart(2, '0');
    return `${value.getFullYear()}-${p(value.getMonth() + 1)}-${p(value.getDate())}`
      + `T${p(value.getHours())}:${p(value.getMinutes())}:${p(value.getSeconds())}`;
  }

  function timestamp(value) {
    if (value instanceof Date) {
      return Number.isNaN(value.getTime()) ? null : timestamp(wallClock(value));
    }
    const raw = text(value);
    if (raw === null) return null;

    const compact = raw.match(COMPACT_TIME);
    let normalized = compact
      ? `${compact[1]}T${compact[2]}:${compact[3]}:${compact[4]}`
      : raw.replace(' ', 'T');

    // ما حمل منطقةً يُحترم كما هو؛ وما خلا منها يُنسب إلى منطقة المصدر.
    if (!HAS_ZONE.test(normalized)) normalized += SOURCE_UTC_OFFSET;

    const parsed = new Date(normalized);
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
  }

  /**
   * تاريخ لم يُفهَم ليس تاريخاً فارغاً.
   * الفراغ قد يعني «لم يُصدَّر»، وعدمُ الفهم يعني «صيغة لا نعرفها» — والثاني
   * يستوجب وقفة لا تجاهلاً. تُميَّز الحالتان هنا ليُبلَّغ عنهما مختلفتين.
   */
  function unparsedTimestamp(value) {
    return text(value) !== null && timestamp(value) === null;
  }

  // الطوبولوجيا مبثوثة في lastname وأحياناً في أعمدة __EMPTY المجاورة.
  // ملف تموز يحمل FDT وحده غالباً، وملف المستخدمين يحمل الأجزاء الثلاثة.
  // غياب جزء ليس خطأ؛ والشكل غير المفهوم يبقى فارغاً بدل التخمين.
  const TOPOLOGY_PART = /\b(FDT|FAT|PORT)\s*[:：]\s*([A-Za-z0-9_-]+)/gi;

  function parseTopology(raw) {
    const source = text(raw);
    const out = { topology_raw: source, fdt_code: null, fat_code: null, port_code: null };
    if (source === null) return out;
    let match;
    TOPOLOGY_PART.lastIndex = 0;
    while ((match = TOPOLOGY_PART.exec(source)) !== null) {
      const part = match[1].toUpperCase();
      const value = match[2];
      if (part === 'FDT' && out.fdt_code === null) out.fdt_code = value;
      else if (part === 'FAT' && out.fat_code === null) out.fat_code = value;
      else if (part === 'PORT' && out.port_code === null) out.port_code = value;
    }
    return out;
  }

  /** يجمع نص الطوبولوجيا من العمود الأصلي وأعمدة الامتداد __EMPTY. */
  function topologyFromRow(row, lastnameHeader) {
    const parts = [];
    if (lastnameHeader && row[lastnameHeader] != null) parts.push(String(row[lastnameHeader]));
    Object.keys(row).forEach((key) => {
      if (/^__EMPTY(_\d+)?$/.test(key) && row[key] != null) parts.push(String(row[key]));
    });
    const joined = parts.join(' ').trim();
    return parseTopology(joined === '' ? null : joined);
  }

  function readField(row, mapping, field) {
    const header = mapping.get(field);
    return header === undefined ? null : row[header];
  }

  /**
   * يحلّل شيت أحداث تفعيل. الهوية هي معرّف الحدث؛ الصف بلا معرّف يُرفض
   * ولا يُلفَّق له مفتاح، لأن مفتاحاً ملفَّقاً يكسر منع التكرار عبر الملفات.
   */
  function parseActivationSheet(rows, options) {
    const opts = options || {};
    const headers = Object.keys(rows[0] || {});
    const { mapping, secretsDropped } = mapHeaders(headers);
    const events = [];
    const rejected = [];
    const lastnameHeader = mapping.get('lastname');

    rows.forEach((row, index) => {
      const eventId = text(readField(row, mapping, 'id'));
      const username = text(readField(row, mapping, 'username'));
      if (eventId === null) { rejected.push({ row: index + 2, reason: 'MISSING_EVENT_ID' }); return; }
      if (username === null) { rejected.push({ row: index + 2, reason: 'MISSING_USERNAME' }); return; }

      const topology = topologyFromRow(row, lastnameHeader);
      events.push({
        saas_event_id: eventId,
        transaction_id: text(readField(row, mapping, 'transaction_id')),
        saas_user_id: null,
        username,
        username_key: username.toLowerCase(),
        event_created_at: timestamp(readField(row, mapping, 'created_at')),
        profile_name: text(readField(row, mapping, 'profile_name')),
        old_expiration: timestamp(readField(row, mapping, 'old_expiration')),
        new_expiration: timestamp(readField(row, mapping, 'new_expiration')),
        activations_count: integer(readField(row, mapping, 'activations_count')),
        raw_parent: text(readField(row, mapping, 'parent')),
        canceled: bool(readField(row, mapping, 'canceled')),
        price: decimal(readField(row, mapping, 'price')),
        user_price: decimal(readField(row, mapping, 'user_price')),
        total_price: decimal(readField(row, mapping, 'total_price')),
        tax_amount: decimal(readField(row, mapping, 'tax_amount')),
        tax_rate: decimal(readField(row, mapping, 'tax_rate')),
        contract_id: text(readField(row, mapping, 'contract_id')),
        card: text(readField(row, mapping, 'card')),
        card_owner: text(readField(row, mapping, 'card_owner')),
        comment: text(readField(row, mapping, 'comment')),
        group_name: text(readField(row, mapping, 'group_name')),
        national_id: text(readField(row, mapping, 'national_id')),
        topology_raw: topology.topology_raw,
        fdt_code: topology.fdt_code,
        fat_code: topology.fat_code,
        port_code: topology.port_code,
        source_sheet: opts.sheetName || null,
        source_row: index + 2,
      });
    });

    return {
      kind: 'ACTIVATION_EVENTS', events, rejected, secretsDropped,
      // تُعدّ ولا تُبتلع: صفرٌ هنا يعني أن كل تاريخ فُهم.
      unparsedDates: rows.reduce(
        (n, row) => n + (unparsedTimestamp(readField(row, mapping, 'created_at')) ? 1 : 0), 0),
    };
  }

  /** يحلّل لقطة مستخدمين. ct_password غير مقروء أصلاً. */
  function parseUsersSheet(rows, options) {
    const opts = options || {};
    const headers = Object.keys(rows[0] || {});
    const { mapping, secretsDropped } = mapHeaders(headers);
    const users = [];
    const rejected = [];
    const lastnameHeader = mapping.get('lastname');

    rows.forEach((row, index) => {
      const userId = text(readField(row, mapping, 'id'));
      const username = text(readField(row, mapping, 'username'));
      if (userId === null) { rejected.push({ row: index + 2, reason: 'MISSING_USER_ID' }); return; }
      if (username === null) { rejected.push({ row: index + 2, reason: 'MISSING_USERNAME' }); return; }

      const topology = topologyFromRow(row, lastnameHeader);
      users.push({
        saas_user_id: userId,
        username,
        username_key: username.toLowerCase(),
        enabled: bool(readField(row, mapping, 'enabled')),
        expiration: timestamp(readField(row, mapping, 'expiration')),
        parent_name: text(readField(row, mapping, 'parent')),
        profile_name: text(readField(row, mapping, 'profile_name')),
        saas_created_at: timestamp(readField(row, mapping, 'created_at')),
        last_online: timestamp(readField(row, mapping, 'last_online')),
        contract_id: text(readField(row, mapping, 'contract_id')),
        group_name: text(readField(row, mapping, 'group_name')),
        company: text(readField(row, mapping, 'company')),
        phone: text(readField(row, mapping, 'phone')),
        national_id: text(readField(row, mapping, 'national_id')),
        topology_raw: topology.topology_raw,
        fdt_code: topology.fdt_code,
        fat_code: topology.fat_code,
        port_code: topology.port_code,
        source_sheet: opts.sheetName || null,
        source_row: index + 2,
      });
    });

    return { kind: 'USERS_SNAPSHOT', users, rejected, secretsDropped };
  }

  /**
   * يقرأ مصنّفاً كاملاً: كل شيت يستوفي عقداً صريحاً يُقرأ، والباقي يُرفض
   * بسبب مُعلن. ثم تُزال التكرارات على مستوى الحدث عبر كل الشيتات معاً،
   * فيستحيل أن يُحتسب حدث مرتين لوروده في شيتين.
   */
  function parseWorkbook(sheets, options) {
    const opts = options || {};
    const sheetResults = [];
    const seenEvents = new Map();
    const events = [];
    const users = [];
    const seenUsers = new Set();
    let duplicates = 0;
    let unparsedDates = 0;
    let secretsDropped = 0;

    (sheets || []).forEach((sheet) => {
      const rows = sheet.rows || [];
      const headers = Object.keys(rows[0] || {});
      const kind = rows.length === 0 ? 'REJECTED' : classifySheet(headers);

      if (kind === 'REJECTED') {
        sheetResults.push({
          sheet: sheet.name, rows: rows.length, kind: 'REJECTED',
          reason: rows.length === 0 ? 'EMPTY_SHEET' : 'CONTRACT_NOT_SATISFIED',
          imported: 0, duplicates: 0,
        });
        return;
      }

      if (kind === 'ACTIVATION_EVENTS') {
        const parsed = parseActivationSheet(rows, { sheetName: sheet.name });
        secretsDropped += parsed.secretsDropped;
        let imported = 0; let dupes = 0;
        parsed.events.forEach((event) => {
          const prior = seenEvents.get(event.saas_event_id);
          if (prior) {
            dupes += 1; duplicates += 1;
            prior.duplicate_sources.push(`${sheet.name}#${event.source_row}`);
            return;
          }
          event.duplicate_sources = [];
          seenEvents.set(event.saas_event_id, event);
          events.push(event);
          imported += 1;
        });
        sheetResults.push({
          sheet: sheet.name, rows: rows.length, kind, imported, duplicates: dupes,
          rejected: parsed.rejected.length, unparsedDates: parsed.unparsedDates,
        });
        unparsedDates += parsed.unparsedDates;
        return;
      }

      const parsed = parseUsersSheet(rows, { sheetName: sheet.name });
      secretsDropped += parsed.secretsDropped;
      let imported = 0; let dupes = 0;
      parsed.users.forEach((user) => {
        if (seenUsers.has(user.saas_user_id)) { dupes += 1; duplicates += 1; return; }
        seenUsers.add(user.saas_user_id);
        users.push(user);
        imported += 1;
      });
      sheetResults.push({
        sheet: sheet.name, rows: rows.length, kind, imported, duplicates: dupes,
        rejected: parsed.rejected.length,
      });
    });

    // ربط الحدث بمعرّف المستخدم متى توفّرت لقطة، فيصير المفتاح مستقراً.
    if (users.length && events.length) {
      const byUsername = new Map(users.map((user) => [user.username_key, user.saas_user_id]));
      events.forEach((event) => {
        if (event.saas_user_id === null) {
          event.saas_user_id = byUsername.get(event.username_key) || null;
        }
      });
    }

    const stamps = events.map((e) => e.event_created_at).filter(Boolean).sort();
    return {
      sheetResults,
      events,
      users,
      duplicateCount: duplicates,
      secretsDropped,
      // مجموع ما لم يُفهَم من التواريخ. غير صفر ⇒ لا تُستورَد قبل الفحص.
      unparsedDates,
      // الحدود مرصودة من البيانات، وهي لا تُثبت التغطية. لذلك يبقى الاكتمال
      // UNKNOWN ما لم يُعلَن صراحة من خارج الملف.
      observedMinCreatedAt: stamps.length ? stamps[0] : null,
      observedMaxCreatedAt: stamps.length ? stamps[stamps.length - 1] : null,
      completenessStatus: opts.declaredCompleteness || 'UNKNOWN',
      sourceRowCount: (sheets || []).reduce((n, s) => n + (s.rows || []).length, 0),
    };
  }

  // ---------------------------------------------------------------------------
  // المطابقة. حتمية بالكامل: معرّف ثم اسم مستخدم مطابق تماماً ثم مراجعة يدوية.
  // لا مطابقة تقريبية بالاسم الشخصي — الأسماء تتكرر، وربطاً خاطئاً هنا يعني
  // إسناد مال إلى وكيل آخر.
  // ---------------------------------------------------------------------------

  function matchSubscriber(candidate, registry) {
    const bySaasId = registry.bySaasId || new Map();
    const byUsername = registry.byUsername || new Map();

    if (candidate.saas_user_id && bySaasId.has(candidate.saas_user_id)) {
      return {
        identity_status: 'MATCHED', match_method: 'SAAS_USER_ID',
        subscriber_id: bySaasId.get(candidate.saas_user_id),
        evidence: { saas_user_id: candidate.saas_user_id },
      };
    }
    const key = candidate.username_key || (candidate.username || '').trim().toLowerCase();
    if (key && byUsername.has(key)) {
      const hits = byUsername.get(key);
      const list = Array.isArray(hits) ? hits : [hits];
      // اسم واحد لمشتركين اثنين تعارض صريح، لا يُحسَم بترجيح.
      if (list.length > 1) {
        return {
          identity_status: 'CONFLICT', match_method: null, subscriber_id: null,
          evidence: { username_key: key, candidates: list.length },
        };
      }
      return {
        identity_status: 'MATCHED', match_method: 'EXACT_USERNAME',
        subscriber_id: list[0], evidence: { username_key: key },
      };
    }
    return {
      identity_status: 'UNMATCHED', match_method: null, subscriber_id: null,
      evidence: { username_key: key || null },
    };
  }

  // ---------------------------------------------------------------------------
  // الجِدّة. NEW ادعاء قوي: يعني أن المشترك لم يوجد قط، ويُبنى عليه مال.
  // لذلك لا تُقال إلا بمصدر مكتمل مُثبت. الملفات الحالية اكتمالها UNKNOWN،
  // فالمخرج الصحيح منها هو NEEDS_REVIEW لا NEW.
  // ---------------------------------------------------------------------------

  const PAID_CATEGORIES = new Set(['PAID_PACKAGE']);

  function classifyNewness(input) {
    const registryPreexisting = Boolean(input.registryPreexisting);
    const completeness = input.sourceCompleteness || 'UNKNOWN';
    const events = input.events || [];
    const packageCategory = input.packageCategory || new Map();

    const qualifying = events.filter((event) => {
      if (event.canceled === true) return false;
      const category = packageCategory.get(event.profile_name) || 'UNKNOWN';
      return PAID_CATEGORIES.has(category);
    });

    const lifetime = events.reduce(
      (max, e) => (Number.isFinite(e.activations_count) && e.activations_count > max
        ? e.activations_count : max), 0);
    const observed = events.length;

    const base = {
      lifetime_activations_count: lifetime || null,
      observed_event_count: observed,
      qualifying_paid_event_count: qualifying.length,
      registry_preexisting: registryPreexisting,
      source_completeness: completeness,
      evidence: {
        canceled_events: events.filter((e) => e.canceled === true).length,
        debt_service_events: events.filter(
          (e) => (packageCategory.get(e.profile_name) || 'UNKNOWN') === 'DEBT_SERVICE').length,
        unknown_package_events: events.filter(
          (e) => (packageCategory.get(e.profile_name) || 'UNKNOWN') === 'UNKNOWN').length,
      },
    };

    // 1. وجود سابق في السجل يحسم الأمر مهما قال الملف.
    if (registryPreexisting) {
      return Object.assign(base, { classification: 'EXISTING', reason_code: 'REGISTRY_PREEXISTING' });
    }
    // 2. تعارض هوية لا يُصنَّف.
    if (input.identityStatus === 'CONFLICT') {
      return Object.assign(base, { classification: 'NEEDS_REVIEW', reason_code: 'IDENTITY_CONFLICT' });
    }
    // 3. عدّاد العمر يتجاوز ما رُصد ⇒ هناك تاريخ خارج الملف ⇒ قديم قطعاً.
    //    هذه الاستنتاج صالح حتى مع مصدر ناقص، لأن الزيادة دليل موجب.
    if (lifetime > observed) {
      return Object.assign(base, {
        classification: 'EXISTING', reason_code: 'LIFETIME_COUNT_EXCEEDS_OBSERVED',
      });
    }
    // 4. لا حدث مدفوع مؤهل ⇒ لا أساس لادعاء اشتراك جديد.
    if (qualifying.length === 0) {
      return Object.assign(base, {
        classification: 'NEEDS_REVIEW',
        reason_code: observed > 0 && events.every((e) => e.canceled === true)
          ? 'CANCELED_ONLY_HISTORY' : 'NO_QUALIFYING_PAID_EVENT',
      });
    }
    // 5. الحارس. تساوي العدّاد مع المرصود يوحي بالجِدّة، لكنه لا يُثبتها إلا
    //    إذا كان المصدر مكتملاً. غير ذلك يبقى للمراجعة.
    if (completeness === 'COMPLETE' && lifetime > 0 && lifetime === observed) {
      return Object.assign(base, {
        classification: 'NEW', reason_code: 'COMPLETE_LIFETIME_HISTORY_OBSERVED',
      });
    }
    return Object.assign(base, {
      classification: 'NEEDS_REVIEW',
      reason_code: completeness === 'PARTIAL' ? 'PARTIAL_SOURCE' : 'UNKNOWN_SOURCE_COMPLETENESS',
    });
  }

  return {
    FORBIDDEN_COLUMNS, HEADER_ALIASES, EVENT_CONTRACT, USER_CONTRACT,
    normalizeHeader, canonicalField, mapHeaders, classifySheet,
    parseTopology, parseActivationSheet, parseUsersSheet, parseWorkbook,
    unparsedTimestamp,
    matchSubscriber, classifyNewness,
  };
});
