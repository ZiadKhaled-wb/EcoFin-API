import { z } from 'zod';
import { IdempotencyKey, IsoTimestamp, Money, Uuid } from './common.js';

/**
 * M01 import (D83): products, customers, suppliers and opening stock from Excel or CSV; M02 (D85)
 * adds the opening installment contracts and the opening cash.
 *
 * Every kind is described ONCE here (`IMPORT_COLUMNS`). The template download, the header matching
 * (`suggestImportMapping`), the Web mapping screen and the error messages all read this list, so a
 * column added here appears everywhere and the template and the parser never disagree. The rules
 * themselves (what is valid, who matches whom) live in SQL, not here.
 */

export const IMPORT_KINDS = [
  'suppliers',
  'products',
  'customers',
  'opening_stock',
  'opening_contracts',
  'opening_cash',
] as const;
export const ImportKind = z.enum(IMPORT_KINDS);
export type ImportKind = z.infer<typeof ImportKind>;

/** The order a shop follows: opening stock needs the products, open contracts need the customers. */
export const IMPORT_KIND_ORDER: readonly ImportKind[] = [
  'suppliers',
  'products',
  'customers',
  'opening_stock',
  'opening_contracts',
  'opening_cash',
];

/** The database's `import_status` enum. */
export const IMPORT_STATUSES = [
  'uploaded',
  'validating',
  'validated',
  'importing',
  'completed',
  'failed',
  'cancelled',
] as const;
export const ImportStatus = z.enum(IMPORT_STATUSES);
export type ImportStatus = z.infer<typeof ImportStatus>;

/** One file: at most this many bytes and data rows (header row and empty rows not counted). */
export const IMPORT_MAX_BYTES = 5 * 1024 * 1024;
export const IMPORT_MAX_ROWS = 5000;
/** The report lists at most this many row errors (`errors_total` is always exact). */
export const IMPORT_MAX_REPORTED_ERRORS = 5000;
export const IMPORT_PREVIEW_ROWS = 20;

// ---------------------------------------------------------------------------------------------
// Columns

/** How a cell is read. SQL repeats the same list (app.import_columns); a test keeps them equal. */
export const IMPORT_COLUMN_TYPES = [
  'text',
  'money',
  'integer',
  'boolean',
  'date',
  'gender',
  'phones',
  'category_path',
  'national_id',
  'serial',
  'eta_type',
] as const;
export type ImportColumnType = (typeof IMPORT_COLUMN_TYPES)[number];

export interface ImportColumnDef {
  /** The field key every layer uses (never the file's own header). */
  key: string;
  label_ar: string;
  label_en: string;
  type: ImportColumnType;
  /** Always needed. */
  required: boolean;
  /** Needed unless another column of the same group is given ("sku or barcode"). */
  requiredOneOf?: string;
  /** Other names shops use for this column, matched after `normalizeImportHeader`. */
  aliases: readonly string[];
  /** One example cell for the template. */
  example: string;
  /** Allowed values when the column is a fixed list (shown in the Help sheet). */
  allowed?: readonly string[];
  help_ar: string;
  help_en: string;
}

const col = (def: ImportColumnDef): ImportColumnDef => def;

const GUARANTOR_RELATION_VALUES = [
  'father',
  'mother',
  'brother',
  'sister',
  'spouse',
  'son',
  'daughter',
  'relative',
  'friend',
  'colleague',
  'employer',
  'neighbour',
  'other',
] as const;

/** The five cells of one guarantor of an opening contract (M02). */
const guarantorColumns = (n: 1 | 2): ImportColumnDef[] => {
  const ar = n === 1 ? 'الأول' : 'الثاني';
  const en = `Guarantor ${n}`;
  return [
    col({
      key: `guarantor${n}_national_id`,
      label_ar: `الرقم القومي للضامن ${ar}`,
      label_en: `${en} national ID`,
      type: 'national_id',
      required: false,
      aliases: [`guarantor ${n} nid`, `ضامن ${n} رقم قومي`],
      example: n === 1 ? '28805050100022' : '',
      help_ar: 'اختياري. ضامن موجود يُعرف بالرقم القومي. ضامن جديد يحتاج الاسم والهاتف أيضاً.',
      help_en:
        'Optional. An existing guarantor is found by national ID. A new one also needs a name and a phone.',
    }),
    col({
      key: `guarantor${n}_name`,
      label_ar: `اسم الضامن ${ar}`,
      label_en: `${en} name`,
      type: 'text',
      required: false,
      aliases: [`guarantor ${n}`, `ضامن ${n}`],
      example: n === 1 ? 'محمود حسن' : '',
      help_ar: 'مطلوب للضامن الجديد فقط.',
      help_en: 'Needed for a new guarantor only.',
    }),
    col({
      key: `guarantor${n}_phone`,
      label_ar: `هاتف الضامن ${ar}`,
      label_en: `${en} phone`,
      type: 'phones',
      required: false,
      aliases: [`guarantor ${n} mobile`, `ضامن ${n} موبايل`],
      example: n === 1 ? '01055550001' : '',
      help_ar: 'مطلوب للضامن الجديد فقط.',
      help_en: 'Needed for a new guarantor only.',
    }),
    col({
      key: `guarantor${n}_address`,
      label_ar: `عنوان الضامن ${ar}`,
      label_en: `${en} address`,
      type: 'text',
      required: false,
      aliases: [`guarantor ${n} location`],
      example: '',
      help_ar: 'حتى 300 حرف.',
      help_en: 'Up to 300 characters.',
    }),
    col({
      key: `guarantor${n}_relation`,
      label_ar: `صلة الضامن ${ar}`,
      label_en: `${en} relation`,
      type: 'text',
      required: false,
      aliases: [`guarantor ${n} relationship`],
      example: n === 1 ? 'brother' : '',
      allowed: GUARANTOR_RELATION_VALUES,
      help_ar: 'صلة القرابة بالعميل. الافتراضي: other.',
      help_en: 'Relation to the customer. Default: other.',
    }),
  ];
};

export const IMPORT_COLUMNS: Record<ImportKind, readonly ImportColumnDef[]> = {
  suppliers: [
    col({
      key: 'name',
      label_ar: 'اسم المورد',
      label_en: 'Supplier name',
      type: 'text',
      required: true,
      aliases: ['supplier', 'supplier name', 'vendor', 'company', 'المورد', 'اسم الشركة', 'الاسم'],
      example: 'شركة النور للتوريدات',
      help_ar: 'مطلوب. الاسم لا يتكرر بين الموردين النشطين.',
      help_en: 'Required. Unique among active suppliers.',
    }),
    col({
      key: 'phone',
      label_ar: 'الهاتف',
      label_en: 'Phone',
      type: 'text',
      required: false,
      aliases: ['mobile', 'tel', 'telephone', 'phone number', 'رقم الهاتف', 'موبايل', 'تليفون'],
      example: '01012345678',
      help_ar: 'رقم واحد. يُحفظ بدون مسافات أو شرطات.',
      help_en: 'One number. Stored without spaces or dashes.',
    }),
    col({
      key: 'tax_registration_no',
      label_ar: 'الرقم الضريبي',
      label_en: 'Tax registration no.',
      type: 'text',
      required: false,
      aliases: ['tax id', 'tax number', 'vat number', 'tax no', 'رقم التسجيل الضريبي'],
      example: '123456789',
      help_ar: 'من 9 إلى 20 رقماً.',
      help_en: '9 to 20 digits.',
    }),
    col({
      key: 'address',
      label_ar: 'العنوان',
      label_en: 'Address',
      type: 'text',
      required: false,
      aliases: ['location'],
      example: 'القاهرة',
      help_ar: 'حتى 300 حرف.',
      help_en: 'Up to 300 characters.',
    }),
    col({
      key: 'payment_terms_days',
      label_ar: 'مدة السداد بالأيام',
      label_en: 'Payment terms (days)',
      type: 'integer',
      required: false,
      aliases: ['payment terms', 'terms', 'credit days', 'مدة السداد', 'أيام السداد'],
      example: '30',
      help_ar: 'عدد صحيح من 0 إلى 365.',
      help_en: 'Whole number from 0 to 365.',
    }),
    col({
      key: 'notes',
      label_ar: 'ملاحظات',
      label_en: 'Notes',
      type: 'text',
      required: false,
      aliases: ['note', 'remarks', 'comment', 'comments', 'ملاحظة'],
      example: '',
      help_ar: 'حتى 1000 حرف.',
      help_en: 'Up to 1000 characters.',
    }),
  ],
  products: [
    col({
      key: 'sku',
      label_ar: 'كود الصنف',
      label_en: 'SKU',
      type: 'text',
      required: false,
      requiredOneOf: 'identity',
      aliases: [
        'item code',
        'product code',
        'code',
        'item no',
        'item number',
        'part number',
        'sku code',
        'كود',
        'كود المنتج',
        'رقم الصنف',
        'الكود',
      ],
      example: 'PH-001',
      help_ar:
        'الكود الذي تتعرف به على الصنف عند إعادة الاستيراد. حروف إنجليزية وأرقام و . _ / - فقط. إن تُرك فارغاً يُستخدم الباركود.',
      help_en:
        'The code that identifies the product on a re-import. Letters, digits and . _ / - only. When empty, the barcode is used.',
    }),
    col({
      key: 'name_ar',
      label_ar: 'اسم الصنف بالعربية',
      label_en: 'Name (Arabic)',
      type: 'text',
      required: false,
      requiredOneOf: 'name',
      aliases: [
        'name',
        'product name',
        'item name',
        'description',
        'اسم الصنف',
        'اسم المنتج',
        'الاسم',
        'البيان',
        'الصنف',
        'المنتج',
      ],
      example: 'هاتف سامسونج A15',
      help_ar: 'مطلوب (أو الاسم الإنجليزي). حتى 150 حرفاً.',
      help_en: 'Required (or the English name). Up to 150 characters.',
    }),
    col({
      key: 'name_en',
      label_ar: 'اسم الصنف بالإنجليزية',
      label_en: 'Name (English)',
      type: 'text',
      required: false,
      requiredOneOf: 'name',
      aliases: ['english name', 'name en', 'الاسم الانجليزي', 'الاسم بالانجليزي'],
      example: 'Samsung A15',
      help_ar: 'اختياري. حتى 150 حرفاً.',
      help_en: 'Optional. Up to 150 characters.',
    }),
    col({
      key: 'cash_price',
      label_ar: 'سعر النقد',
      label_en: 'Cash price',
      type: 'money',
      required: true,
      aliases: [
        'price',
        'selling price',
        'sale price',
        'unit price',
        'retail price',
        'السعر',
        'سعر البيع',
        'سعر الجمهور',
        'سعر الكاش',
      ],
      example: '9000.00',
      help_ar: 'مطلوب. أرقام بحد أقصى خانتين عشريتين، بدون فاصل آلاف (1500 أو 1500.50).',
      help_en: 'Required. Digits with up to 2 decimals, no thousands separator (1500 or 1500.50).',
    }),
    col({
      key: 'barcode',
      label_ar: 'الباركود',
      label_en: 'Barcode',
      type: 'text',
      required: false,
      requiredOneOf: 'identity',
      aliases: ['ean', 'upc', 'ean13', 'bar code', 'باركود'],
      example: '6221234567890',
      help_ar: 'اختياري. إن تُرك فارغاً عند إنشاء صنف جديد يُولَّد تلقائياً.',
      help_en: 'Optional. Generated when empty on a new product.',
    }),
    col({
      key: 'category',
      label_ar: 'التصنيف',
      label_en: 'Category',
      type: 'category_path',
      required: false,
      aliases: ['category name', 'group', 'department', 'type', 'القسم', 'المجموعة', 'الفئة'],
      example: 'هواتف > سامسونج',
      help_ar: 'تصنيف أو تصنيف رئيسي > فرعي. يُنشأ تلقائياً إن لم يوجد.',
      help_en: 'A category, or "parent > child". Created when it does not exist.',
    }),
    col({
      key: 'unit_of_measure',
      label_ar: 'وحدة القياس',
      label_en: 'Unit of measure',
      type: 'text',
      required: false,
      aliases: ['unit', 'uom', 'الوحدة'],
      example: 'piece',
      help_ar: 'حتى 20 حرفاً. الافتراضي: piece.',
      help_en: 'Up to 20 characters. Default: piece.',
    }),
    col({
      key: 'installment_price',
      label_ar: 'سعر التقسيط',
      label_en: 'Installment price',
      type: 'money',
      required: false,
      aliases: ['credit price', 'price installment', 'سعر القسط', 'سعر الأجل'],
      example: '10500.00',
      help_ar: 'اختياري. إن تُرك فارغاً يُحسب من سعر النقد وسياسة التقسيط.',
      help_en: 'Optional. When empty it follows the cash price and the installment policy.',
    }),
    col({
      key: 'tax_class',
      label_ar: 'فئة الضريبة',
      label_en: 'Tax class',
      type: 'text',
      required: false,
      aliases: ['tax', 'vat', 'tax category', 'الضريبة'],
      example: '',
      help_ar: 'اسم فئة ضريبة موجودة. إن تُرك فارغاً تُستخدم فئة المتجر الافتراضية.',
      help_en: "The name of an existing tax class. Empty = the shop's default.",
    }),
    col({
      key: 'warranty_months',
      label_ar: 'الضمان بالشهور',
      label_en: 'Warranty (months)',
      type: 'integer',
      required: false,
      aliases: ['warranty', 'guarantee', 'الضمان', 'مدة الضمان'],
      example: '12',
      help_ar: 'عدد صحيح من 0 إلى 120.',
      help_en: 'Whole number from 0 to 120.',
    }),
    col({
      key: 'is_serialized',
      label_ar: 'له رقم تسلسلي',
      label_en: 'Serialized (IMEI)',
      type: 'boolean',
      required: false,
      aliases: ['serialized', 'has serial', 'imei', 'serial tracked', 'رقم تسلسلي', 'سيريال'],
      example: 'نعم',
      allowed: ['yes', 'no', 'نعم', 'لا'],
      help_ar: 'نعم أو لا. لا يمكن تغييره بعد وجود حركة مخزون.',
      help_en: 'Yes or no. Cannot change once the product has stock movements.',
    }),
    col({
      key: 'min_stock',
      label_ar: 'حد إعادة الطلب',
      label_en: 'Minimum stock',
      type: 'integer',
      required: false,
      aliases: ['min', 'reorder level', 'reorder point', 'low stock', 'الحد الأدنى'],
      example: '5',
      help_ar: 'عدد صحيح من 0.',
      help_en: 'Whole number from 0.',
    }),
    col({
      key: 'eta_item_code',
      label_ar: 'كود الصنف الضريبي',
      label_en: 'ETA item code',
      type: 'text',
      required: false,
      aliases: ['eta code', 'gs1', 'egs', 'كود مصلحة الضرائب'],
      example: '',
      help_ar: 'مع نوع الكود (معاً أو بدونهما).',
      help_en: 'Together with the code type, or neither.',
    }),
    col({
      key: 'eta_item_type',
      label_ar: 'نوع الكود الضريبي',
      label_en: 'ETA item type',
      type: 'eta_type',
      required: false,
      aliases: ['eta type', 'نوع كود الضرائب'],
      example: '',
      allowed: ['EGS', 'GS1'],
      help_ar: 'EGS أو GS1.',
      help_en: 'EGS or GS1.',
    }),
  ],
  customers: [
    col({
      key: 'full_name',
      label_ar: 'اسم العميل',
      label_en: 'Full name',
      type: 'text',
      required: true,
      aliases: ['name', 'customer', 'customer name', 'client', 'client name', 'الاسم', 'العميل'],
      example: 'أحمد محمد علي',
      help_ar: 'مطلوب. من حرفين إلى 150.',
      help_en: 'Required. 2 to 150 characters.',
    }),
    col({
      key: 'phones',
      label_ar: 'أرقام الهاتف',
      label_en: 'Phones',
      type: 'phones',
      required: true,
      aliases: [
        'phone',
        'mobile',
        'tel',
        'telephone',
        'phone number',
        'الهاتف',
        'رقم الهاتف',
        'موبايل',
        'تليفون',
        'رقم الموبايل',
      ],
      example: '01012345678;01112345678',
      help_ar: 'مطلوب. حتى 5 أرقام يفصل بينها ; (فاصلة منقوطة).',
      help_en: 'Required. Up to 5 numbers separated by ;',
    }),
    col({
      key: 'national_id',
      label_ar: 'الرقم القومي',
      label_en: 'National ID',
      type: 'national_id',
      required: false,
      aliases: ['nid', 'id number', 'national id number', 'الرقم القومى', 'رقم قومي', 'البطاقة'],
      example: '29001011234567',
      help_ar: '14 رقماً. منه يؤخذ تاريخ الميلاد والنوع.',
      help_en: '14 digits. Birth date and gender are read from it.',
    }),
    col({
      key: 'birth_date',
      label_ar: 'تاريخ الميلاد',
      label_en: 'Birth date',
      type: 'date',
      required: false,
      aliases: ['birthday', 'date of birth', 'dob', 'تاريخ ميلاد'],
      example: '',
      help_ar: 'YYYY-MM-DD. فقط بدون رقم قومي.',
      help_en: 'YYYY-MM-DD. Only without a national ID.',
    }),
    col({
      key: 'gender',
      label_ar: 'النوع',
      label_en: 'Gender',
      type: 'gender',
      required: false,
      aliases: ['sex', 'الجنس'],
      example: '',
      allowed: ['male', 'female', 'ذكر', 'أنثى'],
      help_ar: 'ذكر أو أنثى. فقط بدون رقم قومي.',
      help_en: 'Male or female. Only without a national ID.',
    }),
    col({
      key: 'address',
      label_ar: 'العنوان',
      label_en: 'Address',
      type: 'text',
      required: false,
      aliases: ['location', 'home address'],
      example: '',
      help_ar: 'حتى 300 حرف.',
      help_en: 'Up to 300 characters.',
    }),
    col({
      key: 'city',
      label_ar: 'المدينة',
      label_en: 'City',
      type: 'text',
      required: false,
      aliases: ['town', 'governorate', 'المحافظة'],
      example: '',
      help_ar: 'حتى 100 حرف.',
      help_en: 'Up to 100 characters.',
    }),
    col({
      key: 'job',
      label_ar: 'الوظيفة',
      label_en: 'Job',
      type: 'text',
      required: false,
      aliases: ['occupation', 'profession', 'المهنة'],
      example: '',
      help_ar: 'حتى 100 حرف.',
      help_en: 'Up to 100 characters.',
    }),
    col({
      key: 'employer',
      label_ar: 'جهة العمل',
      label_en: 'Employer',
      type: 'text',
      required: false,
      aliases: ['company', 'workplace', 'work', 'صاحب العمل'],
      example: '',
      help_ar: 'حتى 150 حرفاً.',
      help_en: 'Up to 150 characters.',
    }),
    col({
      key: 'monthly_income',
      label_ar: 'الدخل الشهري',
      label_en: 'Monthly income',
      type: 'money',
      required: false,
      aliases: ['income', 'salary', 'الدخل', 'المرتب'],
      example: '',
      help_ar: 'أرقام بحد أقصى خانتين عشريتين.',
      help_en: 'Digits with up to 2 decimals.',
    }),
    col({
      key: 'is_business',
      label_ar: 'نشاط تجاري',
      label_en: 'Business',
      type: 'boolean',
      required: false,
      aliases: ['business', 'is company', 'شركة'],
      example: '',
      allowed: ['yes', 'no', 'نعم', 'لا'],
      help_ar: 'نعم أو لا. النشاط التجاري يحتاج رقماً ضريبياً.',
      help_en: 'Yes or no. A business needs a tax registration number.',
    }),
    col({
      key: 'tax_registration_no',
      label_ar: 'الرقم الضريبي',
      label_en: 'Tax registration no.',
      type: 'text',
      required: false,
      aliases: ['tax id', 'tax number', 'vat number', 'رقم التسجيل الضريبي'],
      example: '',
      help_ar: 'من 9 إلى 20 رقماً.',
      help_en: '9 to 20 digits.',
    }),
    col({
      key: 'notes',
      label_ar: 'ملاحظات',
      label_en: 'Notes',
      type: 'text',
      required: false,
      aliases: ['note', 'remarks', 'comment', 'comments', 'ملاحظة'],
      example: '',
      help_ar: 'حتى 1000 حرف.',
      help_en: 'Up to 1000 characters.',
    }),
  ],
  opening_stock: [
    col({
      key: 'sku',
      label_ar: 'كود الصنف',
      label_en: 'SKU',
      type: 'text',
      required: false,
      requiredOneOf: 'product',
      aliases: ['item code', 'product code', 'code', 'item no', 'كود', 'كود المنتج', 'الكود'],
      example: 'PH-001',
      help_ar: 'كود صنف موجود (أو الباركود).',
      help_en: 'The SKU of an existing product (or its barcode).',
    }),
    col({
      key: 'barcode',
      label_ar: 'الباركود',
      label_en: 'Barcode',
      type: 'text',
      required: false,
      requiredOneOf: 'product',
      aliases: ['ean', 'upc', 'bar code', 'باركود'],
      example: '',
      help_ar: 'باركود صنف موجود (أو الكود).',
      help_en: 'The barcode of an existing product (or its SKU).',
    }),
    col({
      key: 'quantity',
      label_ar: 'الكمية',
      label_en: 'Quantity',
      type: 'integer',
      required: false,
      requiredOneOf: 'amount',
      aliases: ['qty', 'stock', 'on hand', 'count', 'الرصيد', 'العدد', 'الكميه'],
      example: '10',
      help_ar: 'عدد صحيح أكبر من صفر، للأصناف بدون رقم تسلسلي.',
      help_en: 'Whole number above zero, for products without serials.',
    }),
    col({
      key: 'serial',
      label_ar: 'الرقم التسلسلي',
      label_en: 'Serial / IMEI',
      type: 'serial',
      required: false,
      requiredOneOf: 'amount',
      aliases: ['imei', 'serial number', 'sn', 'serial no', 'السيريال', 'رقم تسلسلي'],
      example: '',
      help_ar: 'للأصناف ذات الرقم التسلسلي: صف واحد لكل رقم.',
      help_en: 'For serialized products: one row per serial.',
    }),
    col({
      key: 'unit_cost',
      label_ar: 'تكلفة الوحدة',
      label_en: 'Unit cost',
      type: 'money',
      required: true,
      aliases: [
        'cost',
        'cost price',
        'purchase price',
        'buy price',
        'التكلفة',
        'سعر الشراء',
        'سعر التكلفة',
      ],
      example: '7000.00',
      help_ar: 'مطلوب. تكلفة الوحدة الواحدة بحد أقصى خانتين عشريتين.',
      help_en: 'Required. Cost of one unit, up to 2 decimals.',
    }),
  ],
  opening_contracts: [
    col({
      key: 'contract_ref',
      label_ar: 'رقم العقد (النظام القديم)',
      label_en: 'Contract number (old system)',
      type: 'text',
      required: true,
      aliases: [
        'contract',
        'contract no',
        'contract number',
        'ref',
        'reference',
        'old contract number',
        'رقم العقد',
        'العقد',
      ],
      example: 'K-1001',
      help_ar: 'مطلوب. نفس الرقم يتكرر في كل أقساط العقد ولا يتكرر بين عقدين.',
      help_en:
        'Required. The same number on every installment row of the contract; unique per contract.',
    }),
    col({
      key: 'customer_national_id',
      label_ar: 'الرقم القومي للعميل',
      label_en: 'Customer national ID',
      type: 'national_id',
      required: false,
      requiredOneOf: 'customer',
      aliases: [
        'national id',
        'nid',
        'id number',
        'customer nid',
        'الرقم القومي',
        'رقم قومي',
        'بطاقة العميل',
      ],
      example: '29101010100501',
      help_ar: 'العميل يجب أن يكون مسجلاً (استورد العملاء أولاً). الرقم القومي أو الهاتف.',
      help_en: 'The customer must already exist (import customers first). National ID or phone.',
    }),
    col({
      key: 'customer_phone',
      label_ar: 'هاتف العميل',
      label_en: 'Customer phone',
      type: 'phones',
      required: false,
      requiredOneOf: 'customer',
      aliases: [
        'phone',
        'mobile',
        'tel',
        'customer mobile',
        'الهاتف',
        'رقم الهاتف',
        'موبايل العميل',
        'تليفون العميل',
      ],
      example: '',
      help_ar: 'يُستخدم عند غياب الرقم القومي.',
      help_en: 'Used when there is no national ID.',
    }),
    col({
      key: 'branch_code',
      label_ar: 'كود الفرع',
      label_en: 'Branch code',
      type: 'text',
      required: false,
      aliases: ['branch', 'الفرع', 'فرع'],
      example: '',
      help_ar: 'اختياري. الافتراضي: الفرع الرئيسي.',
      help_en: 'Optional. Default: the main branch.',
    }),
    col({
      key: 'contract_date',
      label_ar: 'تاريخ العقد',
      label_en: 'Contract date',
      type: 'date',
      required: true,
      aliases: [
        'signing date',
        'sale date',
        'contract signing date',
        'تاريخ التعاقد',
        'تاريخ البيع',
      ],
      example: '2025-03-15',
      help_ar: 'مطلوب. تاريخ التوقيع في النظام القديم (YYYY-MM-DD).',
      help_en: 'Required. The signing date in the old system (YYYY-MM-DD).',
    }),
    col({
      key: 'original_total',
      label_ar: 'إجمالي العقد الأصلي',
      label_en: 'Original total',
      type: 'money',
      required: true,
      aliases: [
        'total',
        'contract total',
        'installment price',
        'total price',
        'إجمالي العقد',
        'اجمالي العقد',
        'سعر التقسيط',
        'الاجمالي',
      ],
      example: '12000',
      help_ar: 'مطلوب. سعر التقسيط الذي وقّع عليه العميل.',
      help_en: 'Required. The installment price the customer signed for.',
    }),
    col({
      key: 'paid_before',
      label_ar: 'المدفوع سابقاً',
      label_en: 'Paid before',
      type: 'money',
      required: true,
      aliases: [
        'paid',
        'total paid',
        'paid so far',
        'paid to date',
        'المدفوع',
        'المدفوع سابقا',
        'ما تم دفعه',
      ],
      example: '3000',
      help_ar:
        'مطلوب (0 إن لم يُدفع شيء). كل ما دُفع قبل النقل بما فيه المقدم. المتبقي = الإجمالي − المدفوع.',
      help_en:
        'Required (0 if nothing). Everything paid before the migration, down payment included. Left = total − paid.',
    }),
    col({
      key: 'frequency',
      label_ar: 'دورية السداد',
      label_en: 'Frequency',
      type: 'text',
      required: false,
      aliases: ['period', 'payment frequency', 'الدورية'],
      example: 'monthly',
      allowed: ['monthly', 'weekly', 'شهري', 'أسبوعي'],
      help_ar: 'اختياري. الافتراضي: شهري.',
      help_en: 'Optional. Default: monthly.',
    }),
    col({
      key: 'remaining_principal',
      label_ar: 'المتبقي من أصل المبلغ',
      label_en: 'Remaining principal',
      type: 'money',
      required: false,
      aliases: ['principal left', 'remaining price', 'المتبقي أصل'],
      example: '',
      help_ar: 'اختياري، مع المتبقي من الربح. إن لم يُذكرا فكل المتبقي أصل والربح صفر.',
      help_en:
        'Optional, together with the remaining profit. Without both, everything left is principal and the profit is 0.',
    }),
    col({
      key: 'remaining_profit',
      label_ar: 'المتبقي من الربح',
      label_en: 'Remaining profit',
      type: 'money',
      required: false,
      aliases: ['profit left', 'remaining markup', 'المتبقي ربح'],
      example: '',
      help_ar: 'اختياري، مع المتبقي من أصل المبلغ. مجموعهما = مجموع الأقساط.',
      help_en:
        'Optional, together with the remaining principal. Their sum must equal the installments.',
    }),
    col({
      key: 'notes',
      label_ar: 'ملاحظات',
      label_en: 'Notes',
      type: 'text',
      required: false,
      aliases: ['note', 'remarks', 'comment', 'comments', 'ملاحظة'],
      example: '',
      help_ar: 'حتى 500 حرف.',
      help_en: 'Up to 500 characters.',
    }),
    col({
      key: 'due_date',
      label_ar: 'تاريخ الاستحقاق',
      label_en: 'Due date',
      type: 'date',
      required: true,
      aliases: [
        'due',
        'installment date',
        'payment date',
        'تاريخ القسط',
        'موعد القسط',
        'الاستحقاق',
      ],
      example: '2026-11-15',
      help_ar: 'مطلوب. صف لكل قسط متبقٍ.',
      help_en: 'Required. One row per remaining installment.',
    }),
    col({
      key: 'amount',
      label_ar: 'المتبقي من القسط',
      label_en: 'Installment amount left',
      type: 'money',
      required: true,
      aliases: [
        'installment',
        'installment amount',
        'installment left',
        'remaining',
        'remaining amount',
        'left',
        'القسط',
        'قيمة القسط',
        'المتبقي',
        'المبلغ المتبقي',
      ],
      example: '1000',
      help_ar: 'مطلوب. ما بقي من القسط (قسط مدفوع جزئياً يحمل الجزء غير المدفوع فقط).',
      help_en:
        'Required. What is left on the installment (one paid in part carries only its unpaid part).',
    }),
    ...guarantorColumns(1),
    ...guarantorColumns(2),
  ],
  opening_cash: [
    col({
      key: 'branch_code',
      label_ar: 'كود الفرع',
      label_en: 'Branch code',
      type: 'text',
      required: false,
      aliases: ['branch', 'الفرع', 'فرع'],
      example: '',
      help_ar: 'اختياري. الافتراضي: الفرع الرئيسي.',
      help_en: 'Optional. Default: the main branch.',
    }),
    col({
      key: 'account_name',
      label_ar: 'اسم الحساب',
      label_en: 'Account name',
      type: 'text',
      required: true,
      aliases: ['account', 'name', 'safe', 'bank', 'الحساب', 'اسم الخزنة', 'اسم البنك', 'الاسم'],
      example: 'الخزنة الرئيسية',
      help_ar: 'مطلوب. حساب موجود بنفس الاسم في الفرع يُستخدم، وإلا يُنشأ.',
      help_en:
        'Required. An existing account of the branch with this name is used, else it is created.',
    }),
    col({
      key: 'kind',
      label_ar: 'نوع الحساب',
      label_en: 'Account kind',
      type: 'text',
      required: true,
      aliases: ['type', 'account type', 'النوع'],
      example: 'safe',
      allowed: ['safe', 'bank', 'خزينة', 'بنك'],
      help_ar: 'مطلوب: خزينة أو بنك. الأدراج ومحافظ المحصلين لا تُستورد.',
      help_en: 'Required: safe or bank. Drawers and collector wallets are not imported.',
    }),
    col({
      key: 'bank_shop_wide',
      label_ar: 'بنك لكل المتجر',
      label_en: 'Shop-wide bank',
      type: 'boolean',
      required: false,
      aliases: ['shop wide', 'all branches', 'لكل الفروع'],
      example: '',
      allowed: ['yes', 'no', 'نعم', 'لا'],
      help_ar: 'للبنك فقط: نعم = حساب واحد لكل الفروع.',
      help_en: 'Banks only: yes = one account for every branch.',
    }),
    col({
      key: 'balance',
      label_ar: 'الرصيد',
      label_en: 'Balance',
      type: 'money',
      required: true,
      aliases: ['opening balance', 'amount', 'cash', 'الرصيد الافتتاحي', 'رصيد افتتاحي', 'المبلغ'],
      example: '5000',
      help_ar: 'مطلوب. الرصيد الافتتاحي (0 ينشئ الحساب فقط). يُسجل مرة واحدة على حساب بلا حركات.',
      help_en:
        'Required. The opening balance (0 only creates the account). Posted once, on an account with no movements.',
    }),
  ],
};

export function importColumn(kind: ImportKind, key: string): ImportColumnDef | undefined {
  return IMPORT_COLUMNS[kind].find((c) => c.key === key);
}

// ---------------------------------------------------------------------------------------------
// Header matching (shared by the server and the Web mapping screen)

const ARABIC_INDIC = /[٠-٩۰-۹]/g;

/**
 * A header as a comparison key: lower case, Arabic digits as 0-9, alef / yaa / taa marbuta forms
 * merged, tatweel and harakat removed, the Arabic article "ال" dropped from long words, everything
 * that is not a letter or digit dropped ("Item-Code", "item code" and "ITEM_CODE" all match).
 */
export function normalizeImportHeader(header: string): string {
  return header
    .normalize('NFKC')
    .toLowerCase()
    .replace(ARABIC_INDIC, (d) => String(d.charCodeAt(0) & 0xf))
    .replace(/[أإآٱ]/g, 'ا')
    .replace(/ة/g, 'ه')
    .replace(/ى/g, 'ي')
    .replace(/[ـً-ْ]/g, '')
    .split(/[^\p{L}\p{N}]+/u)
    .map((w) => (w.length > 4 && w.startsWith('ال') ? w.slice(2) : w))
    .join('');
}

function headerKeys(def: ImportColumnDef): { exact: Set<string>; loose: Set<string> } {
  return {
    exact: new Set([normalizeImportHeader(def.key), normalizeImportHeader(def.label_en)]),
    loose: new Set([
      normalizeImportHeader(def.label_ar),
      ...def.aliases.map(normalizeImportHeader),
    ]),
  };
}

export interface ImportMappingSuggestion {
  /** field key → the file's header, for every field a header was found for. */
  mapping: Record<string, string>;
  /** Headers no field took (they are ignored, and listed as a warning). */
  unmapped_headers: string[];
  /** Field keys still missing for the file to be importable (a group counts as one entry). */
  missing_required: string[];
}

/** The fields that must still be mapped: required ones, and one per unmet "one of" group. */
export function missingImportColumns(kind: ImportKind, mapped: Iterable<string>): string[] {
  const have = new Set(mapped);
  const missing: string[] = [];
  const groups = new Map<string, string[]>();
  for (const c of IMPORT_COLUMNS[kind]) {
    if (c.required && !have.has(c.key)) missing.push(c.key);
    if (c.requiredOneOf)
      groups.set(c.requiredOneOf, [...(groups.get(c.requiredOneOf) ?? []), c.key]);
  }
  for (const keys of groups.values()) {
    if (!keys.some((k) => have.has(k))) missing.push(keys.join('|'));
  }
  return missing;
}

/**
 * Matches the file's headers to the kind's fields by key, English label, Arabic label and aliases.
 * Exact key / English label matches win over looser ones; a header serves one field and a field
 * takes one header (the first in the file).
 */
export function suggestImportMapping(
  kind: ImportKind,
  headers: readonly string[],
): ImportMappingSuggestion {
  const mapping: Record<string, string> = {};
  const used = new Set<number>();
  const normalized = headers.map(normalizeImportHeader);
  for (const pass of ['exact', 'loose'] as const) {
    for (const def of IMPORT_COLUMNS[kind]) {
      if (mapping[def.key] !== undefined) continue;
      const keys = headerKeys(def)[pass];
      const at = normalized.findIndex((h, i) => h !== '' && !used.has(i) && keys.has(h));
      if (at >= 0) {
        mapping[def.key] = headers[at] as string;
        used.add(at);
      }
    }
  }
  return {
    mapping,
    unmapped_headers: headers.filter((h, i) => !used.has(i) && h.trim() !== ''),
    missing_required: missingImportColumns(kind, Object.keys(mapping)),
  };
}

// ---------------------------------------------------------------------------------------------
// Requests

/** field key → the header of the file that holds it. */
export const ImportMapping = z.record(z.string().min(1).max(60), z.string().min(1).max(200));
export type ImportMapping = z.infer<typeof ImportMapping>;

const SheetName = z.string().trim().min(1).max(100);

export const ImportKindParams = z.object({ kind: ImportKind }).strict();
export type ImportKindParams = z.infer<typeof ImportKindParams>;

export const ImportTemplateQuery = z
  .object({ format: z.enum(['xlsx', 'csv']).default('xlsx') })
  .strict();
export type ImportTemplateQuery = z.infer<typeof ImportTemplateQuery>;

export const ImportIdParams = z.object({ id: Uuid }).strict();
export type ImportIdParams = z.infer<typeof ImportIdParams>;

/**
 * `POST /api/imports/inspect`: reads the uploaded file and answers what is in it (nothing is
 * created). The Web shows the sheets, the headers, a few rows and the suggested mapping.
 */
export const InspectImportBody = z
  .object({ kind: ImportKind, file_id: Uuid, sheet: SheetName.optional() })
  .strict();
export type InspectImportBody = z.infer<typeof InspectImportBody>;

export const ImportInspection = z.object({
  kind: ImportKind,
  file_type: z.enum(['csv', 'xlsx']),
  sheets: z.array(z.string()),
  sheet: z.string().nullable(),
  headers: z.array(z.string()),
  total_rows: z.number().int().min(0),
  /** The first rows, cell text keyed by header. */
  sample: z.array(z.record(z.string())),
  suggestion: z.object({
    mapping: ImportMapping,
    unmapped_headers: z.array(z.string()),
    missing_required: z.array(z.string()),
  }),
});
export type ImportInspection = z.infer<typeof ImportInspection>;

/**
 * `POST /api/imports` (import.data): reads the file, checks every row and saves nothing but the
 * job. `mapping` overrides the automatic header matching (`field → header`); `branch_id` is for
 * opening stock only.
 */
export const CreateImportBody = z
  .object({
    kind: ImportKind,
    file_id: Uuid,
    branch_id: Uuid.optional(),
    sheet: SheetName.optional(),
    mapping: ImportMapping.optional(),
    idempotency_key: IdempotencyKey,
  })
  .strict()
  .superRefine((b, ctx) => {
    if (b.kind === 'opening_stock' && b.branch_id === undefined) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['branch_id'], message: 'Required' });
    }
    if (b.kind !== 'opening_stock' && b.branch_id !== undefined) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['branch_id'], message: 'Not used' });
    }
    for (const key of Object.keys(b.mapping ?? {})) {
      if (importColumn(b.kind, key) === undefined) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['mapping', key], message: 'Unknown' });
      }
    }
  });
export type CreateImportBody = z.infer<typeof CreateImportBody>;

export const RunImportBody = z.object({ idempotency_key: IdempotencyKey }).strict();
export type RunImportBody = z.infer<typeof RunImportBody>;

export const ImportListQuery = z
  .object({
    kind: ImportKind.optional(),
    status: ImportStatus.optional(),
    limit: z.coerce.number().int().min(1).max(100).default(25),
    cursor: z.string().min(1).max(200).optional(),
  })
  .strict();
export type ImportListQuery = z.infer<typeof ImportListQuery>;
export type ImportListQueryInput = z.input<typeof ImportListQuery>;

// ---------------------------------------------------------------------------------------------
// Report

/** Row-level codes. They appear only inside a report, never as an HTTP error. */
export const IMPORT_ROW_ERROR_CODES = [
  'IMPORT_REQUIRED',
  'IMPORT_INVALID_VALUE',
  'IMPORT_DUPLICATE_ROW',
  'IMPORT_AMBIGUOUS_MATCH',
  'IMPORT_APPLY_FAILED',
  'PRODUCT_ARCHIVED',
  'PRODUCT_NOT_FOUND',
  'PRODUCT_SKU_TAKEN',
  'PRODUCT_BARCODE_TAKEN',
  'PRODUCT_SERIAL_LOCKED',
  'PRODUCT_CATEGORY_ARCHIVED',
  'CATEGORY_DEPTH',
  'CATEGORY_NAME_TAKEN',
  'CUSTOMER_NATIONAL_ID_TAKEN',
  'CUSTOMER_NATIONAL_ID_LOCKED',
  'NATIONAL_ID_INVALID',
  'SUPPLIER_PHONE_TAKEN',
  'SUPPLIER_NAME_TAKEN',
  'SERIAL_INVALID',
  'SERIAL_TAKEN',
  'UNIT_NOT_ALLOWED',
  'UNIT_REQUIRED',
  'OPENING_STOCK_LOCKED',
  'TAX_CLASS_NOT_FOUND',
  'MODULE_NOT_IN_PLAN',
  'OUT_OF_STOCK',
  // M02
  'IMPORT_CONTRACT_ROWS_DIFFER',
  'IMPORT_CONTRACT_NOT_BALANCED',
  'IMPORT_CONTRACT_EXISTS',
  'IMPORT_CUSTOMER_NOT_FOUND',
  'IMPORT_GUARANTOR_INCOMPLETE',
  'IMPORT_ACCOUNT_KIND',
  'CASH_ACCOUNT_HAS_MOVEMENTS',
  'CASH_ACCOUNT_INACTIVE',
  'CASH_ACCOUNT_NAME_TAKEN',
  'DAY_CLOSED',
  'POLICY_NOT_SET',
] as const;
export const ImportRowErrorCode = z.enum(IMPORT_ROW_ERROR_CODES);
export type ImportRowErrorCode = z.infer<typeof ImportRowErrorCode>;

export const ImportRowError = z.object({
  /** The row's number in the file (the header is row 1), as Excel shows it. */
  row: z.number().int().min(1),
  /** The field key, or null when the problem is the row as a whole. */
  column: z.string().nullable(),
  code: ImportRowErrorCode,
  /** A short technical message in English; the client shows its own text for the code. */
  message: z.string(),
});
export type ImportRowError = z.infer<typeof ImportRowError>;

export const ImportRowAction = z.enum(['create', 'update', 'unchanged']);
export type ImportRowAction = z.infer<typeof ImportRowAction>;

export const ImportWarning = z.object({
  code: z.enum(['IMPORT_UNKNOWN_COLUMN', 'IMPORT_COLUMN_IGNORED', 'IMPORT_NOTE']),
  message: z.string(),
  column: z.string().nullable(),
});
export type ImportWarning = z.infer<typeof ImportWarning>;

export const ImportPreviewRow = z.object({
  row: z.number().int().min(1),
  action: ImportRowAction,
  /** Field key → text. National IDs are masked. */
  values: z.record(z.string().nullable()),
});
export type ImportPreviewRow = z.infer<typeof ImportPreviewRow>;

export const ImportActions = z.object({
  create: z.number().int().min(0),
  update: z.number().int().min(0),
  unchanged: z.number().int().min(0),
});
export type ImportActions = z.infer<typeof ImportActions>;

/** Opening contracts (M02): the dry run's totals. */
export const ImportContractsSummary = z.object({
  contracts: z.number().int().min(0),
  lines: z.number().int().min(0),
  open_total: Money,
  overdue_total: Money,
  overdue_contracts: z.number().int().min(0),
  new_guarantors: z.number().int().min(0),
});
export type ImportContractsSummary = z.infer<typeof ImportContractsSummary>;

/** Opening contracts (M02): one contract of the file, as the dry run shows it. */
export const ImportContractPreview = z.object({
  row: z.number().int().min(1),
  contract_ref: z.string(),
  customer: z.string().nullable(),
  lines: z.number().int().min(1),
  open_total: Money,
  /** What is already late today; N04 reacts to it the next night (never a fee). */
  overdue_total: Money,
  overdue_days: z.number().int().min(0),
  new_guarantors: z.number().int().min(0),
});
export type ImportContractPreview = z.infer<typeof ImportContractPreview>;

export const ImportReport = z.object({
  columns: z.object({
    mapping: ImportMapping,
    unmapped_headers: z.array(z.string()),
  }),
  sheet: z.string().nullable(),
  branch_id: Uuid.nullable(),
  warnings: z.array(ImportWarning),
  errors: z.array(ImportRowError),
  errors_total: z.number().int().min(0),
  errors_truncated: z.boolean(),
  actions: ImportActions,
  preview: z.array(ImportPreviewRow),
  will_create_categories: z.array(z.string()),
  /** Filled when the import ran: what was saved. */
  applied: ImportActions.nullable(),
  /** Why the import failed outside the rows (a thrown database error), if it did. */
  failure: z.string().nullable(),
  /** Opening contracts only (at most 200 contracts are listed). */
  summary: ImportContractsSummary.optional(),
  contracts: z.array(ImportContractPreview).optional(),
});
export type ImportReport = z.infer<typeof ImportReport>;

export const ImportUserRef = z.object({ id: Uuid, name: z.string() });
export type ImportUserRef = z.infer<typeof ImportUserRef>;

const ImportJobBase = z.object({
  id: Uuid,
  kind: ImportKind,
  status: ImportStatus,
  file_id: Uuid.nullable(),
  file_name: z.string().nullable(),
  /** The CSV of row errors of a failed run (download it through the files API). */
  result_file_id: Uuid.nullable(),
  branch_id: Uuid.nullable(),
  rows_total: z.number().int().min(0),
  rows_ok: z.number().int().min(0),
  rows_failed: z.number().int().min(0),
  created_at: IsoTimestamp,
  finished_at: IsoTimestamp.nullable(),
  created_by: ImportUserRef.nullable(),
});

export const ImportJob = ImportJobBase.extend({ report: ImportReport });
export type ImportJob = z.infer<typeof ImportJob>;

export const ImportJobSummary = ImportJobBase.extend({
  actions: ImportActions.nullable(),
  errors_total: z.number().int().min(0),
});
export type ImportJobSummary = z.infer<typeof ImportJobSummary>;

export const ImportListResponse = z.object({
  items: z.array(ImportJobSummary),
  next_cursor: z.string().nullable(),
});
export type ImportListResponse = z.infer<typeof ImportListResponse>;

/** Detail of IMPORT_MISSING_COLUMNS: the fields (or "a|b" groups) the file lacks. */
export const ImportMissingColumnsDetail = z.object({
  columns: z.array(z.string()),
  headers: z.array(z.string()),
});
export type ImportMissingColumnsDetail = z.infer<typeof ImportMissingColumnsDetail>;

/** Detail of IMPORT_NOT_VALIDATED: the job's real status. */
export const ImportNotValidatedDetail = z.object({ status: ImportStatus });
export type ImportNotValidatedDetail = z.infer<typeof ImportNotValidatedDetail>;
