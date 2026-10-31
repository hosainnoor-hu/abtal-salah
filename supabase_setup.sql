-- ============================================================
--  🕌 أبطال الطهارة والصلاة — إعداد قاعدة بيانات Supabase
--  انسخ هذا الملف كاملاً والصقه في:  SQL Editor ← Run
-- ============================================================

-- ------------------------------------------------------------
-- 1) جدول التقدم (تسطب سجلًا واحدًا لكل مستخدم)
--    يحفظ: خطوات الوضوء، الصلوات المكتشفة، النجوم، الشهادة
-- ------------------------------------------------------------
create table if not exists public.progress (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  kid_name      text default '',
  stars         integer not null default 0 check (stars >= 0),
  wudu_done     jsonb not null default '[]'::jsonb,   -- مثال: [0,1,2]
  seen_prayers  jsonb not null default '[]'::jsonb,   -- مثال: [0,1]
  stage_certs   jsonb not null default '[]'::jsonb,   -- شهادات المراحل
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2) جدول الملاحظات (دفتر ملاحظات الطفل)
-- ------------------------------------------------------------
create table if not exists public.notes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  section    text not null default 'general',  -- wudu | prayer | quiz | general
  title      text not null default '',
  body       text not null default '',
  is_pinned  boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists notes_user_idx on public.notes(user_id);
create index if not exists notes_user_created_idx on public.notes(user_id, created_at desc);

-- ------------------------------------------------------------
-- 3) تفعيل تسجيل الدخول المجهول (مناسب للأطفال: بلا كلمة مرور)
--    يمكن تخطي هذه الخطوة واستخدام البريد إن رغبت
-- ------------------------------------------------------------
-- من لوحة التحكم: Authentication → Providers → Anonymous → Enable
-- (هنا نسمح فقط لغير المجهولين باستخدام حسابهم المجهول كمفتاح)

-- ------------------------------------------------------------
-- 4) تفعيل Row Level Security (حماية البيانات)
--    كل مستخدم يرى ويعدّل بياناته فقط — لا أحد يرى بيانات غيره
-- ------------------------------------------------------------
alter table public.progress enable row level security;
alter table public.notes    enable row level security;

-- --- سياسات جدول progress ---
drop policy if exists "own progress read"   on public.progress;
drop policy if exists "own progress insert" on public.progress;
drop policy if exists "own progress update" on public.progress;
drop policy if exists "own progress delete" on public.progress;

create policy "own progress read"
  on public.progress for select
  using (auth.uid() = user_id);

create policy "own progress insert"
  on public.progress for insert
  with check (auth.uid() = user_id);

create policy "own progress update"
  on public.progress for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "own progress delete"
  on public.progress for delete
  using (auth.uid() = user_id);

-- --- سياسات جدول notes ---
drop policy if exists "own notes read"   on public.notes;
drop policy if exists "own notes insert" on public.notes;
drop policy if exists "own notes update" on public.notes;
drop policy if exists "own notes delete" on public.notes;

create policy "own notes read"
  on public.notes for select
  using (auth.uid() = user_id);

create policy "own notes insert"
  on public.notes for insert
  with check (auth.uid() = user_id);

create policy "own notes update"
  on public.notes for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "own notes delete"
  on public.notes for delete
  using (auth.uid() = user_id);

-- ------------------------------------------------------------
-- 5) دالة مساعدة: تحديث updated_at تلقائياً
-- ------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_progress_updated on public.progress;
create trigger trg_progress_updated
  before update on public.progress
  for each row execute function public.set_updated_at();

drop trigger if exists trg_notes_updated on public.notes;
create trigger trg_notes_updated
  before update on public.notes
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- 6) منع تجاوز النجوم للحد الأقصى + إنشاء سجل تلقائي عند أول دخول
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.progress (user_id, kid_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'kid_name',''))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------
-- 7) تقييد طول الملاحظات وتنظيف المدخلات
-- ------------------------------------------------------------
alter table public.notes drop constraint if exists notes_body_len;
alter table public.notes
  add constraint notes_body_len check (char_length(body) <= 2000);

alter table public.notes drop constraint if exists notes_title_len;
alter table public.notes
  add constraint notes_title_len check (char_length(title) <= 120);

alter table public.progress drop constraint if exists progress_stars_max;
alter table public.progress
  add constraint progress_stars_max check (stars <= 100000);

-- ------------------------------------------------------------
-- 8) جوال الأب + استعادة الحساب (طلب المستخدم: رقم جوال الأب إلزامي)
--    يُحفظ في جدول منفصل محميّ حتى لا يظهر في أي قائمة شهرة.
-- ------------------------------------------------------------
create table if not exists public.account_recovery (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  username      text not null,
  parent_phone  text not null,
  created_at    timestamptz not null default now()
);
create index if not exists recovery_lookup_idx
  on public.account_recovery (lower(parent_phone), lower(username));

alter table public.account_recovery enable row level security;

drop policy if exists "own recovery read"   on public.account_recovery;
drop policy if exists "own recovery insert" on public.account_recovery;
drop policy if exists "own recovery update" on public.account_recovery;
drop policy if exists "own recovery delete" on public.account_recovery;

create policy "own recovery read"
  on public.account_recovery for select using (auth.uid() = user_id);
create policy "own recovery insert"
  on public.account_recovery for insert with check (auth.uid() = user_id);
create policy "own recovery update"
  on public.account_recovery for update
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own recovery delete"
  on public.account_recovery for delete using (auth.uid() = user_id);

-- ------------------------------------------------------------
-- 9) دالة الاستعادة: جوال الأب + اسم البطل → البريد المسجَّل به
--    SECURITY DEFINER لأنها تبحث في حسابات الآخرين بشكل مقصود.
--    لا تُرجع إلا البريد (ومُموَّه في الواجهة)، ولا تُرجع أي بيانات أخرى.
--    إعادة تعيين كلمة المرور نفسها تتطلب فتح رابط يصلك للبريد → عاملان معاً.
-- ------------------------------------------------------------
create or replace function public.find_account(p_phone text, p_username text)
returns table (account_email text)
language sql
stable
security definer set search_path = public
as $$
  select u.email::text as account_email
  from public.account_recovery r
  join auth.users u on u.id = r.user_id
  where nullif(trim(p_phone),'') is not null
    and nullif(trim(p_username),'') is not null
    and lower(regexp_replace(r.parent_phone, '[^0-9+]', '', 'g'))
        = lower(regexp_replace(p_phone,      '[^0-9+]', '', 'g'))
    and lower(trim(r.username)) = lower(trim(p_username))
  limit 1;
$$;

revoke all on function public.find_account(text, text) from public, anon;
grant execute on function public.find_account(text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 10) قائمة الشهرة — تعرض الاسم والنجوم فقط
--     لا تحتوي على: جوال، بريد، ملاحظات، خطوات وضوء، صلوات، ولا user_id
-- ------------------------------------------------------------
create or replace view public.leaderboard
with (security_invoker = off) as
  select kid_name, stars
  from public.progress
  where kid_name is not null
    and btrim(kid_name) <> ''
    and stars > 0
  order by stars desc, kid_name asc
  limit 50;

grant select on public.leaderboard to anon, authenticated;

-- ✅ انتهى. انتقل الآن إلى: Authentication → Providers → Anonymous → Enable
--    ثم انسخ مفتاح anon من: Project Settings → API
