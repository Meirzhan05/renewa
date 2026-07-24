alter table public.profiles
  add column if not exists avatar_key text not null default 'sage',
  add column if not exists onboarding_completed boolean not null default false;

-- Existing accounts should keep their current dashboard entry behavior.
-- Profiles created after this migration complete onboarding in the iOS app.
update public.profiles
set onboarding_completed = true
where onboarding_completed = false;

comment on column public.profiles.avatar_key is
  'Preset avatar identifier today; may hold a Supabase Storage object key in a future migration.';
