// ملف الإعداد المركزى — يجعل كل الأجهزة (طلاب/معلمين) تقرأ من Supabase تلقائياً.
// ضع هذا الملف بجانب index.html على الاستضافة (Cloudflare / GitHub).
// استبدل url و key ببيانات مشروعك من Supabase (Project Settings → API).
window.EBDA_CONFIG = {
  supa: {
    url: "https://XXXX.supabase.co",   // Project URL (بدون /rest/v1)
    key: "eyJ...ANON_PUBLIC_KEY...",    // anon public key فقط
    table: "ebda_state",
    row: "main"
  },
  readSrc: "supa"
};
