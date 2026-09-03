-- ============================================================
-- NEXT CONVERSION · Gestión de proyectos — Esquema Supabase
-- Modelo: un único espacio de trabajo compartido para tu equipo.
-- Cómo usarlo: Supabase Dashboard -> SQL Editor -> pega y ejecuta.
-- ============================================================

-- ---------- 1. PERFILES (ligado a auth.users) ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nombre     text,
  rol        text not null default 'miembro' check (rol in ('admin','miembro')),
  created_at timestamptz default now()
);

-- Crear perfil automáticamente al registrarse un usuario
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', new.email));
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 2. Utilidad: updated_at automático ----------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

-- ---------- 3. CLIENTES ----------
create table if not exists public.clientes (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null,
  estado      text,
  sector      text,
  responsable text,
  web         text,
  contacto    text,
  email       text,
  telefono    text,
  enlaces     text,
  notas       text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
create trigger trg_clientes_updated before update on public.clientes
  for each row execute function public.set_updated_at();

-- ---------- 4. PROYECTOS ----------
create table if not exists public.proyectos (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null,
  cliente_id    uuid references public.clientes(id) on delete set null,
  estado        text,
  tipo          text,
  responsable   text,
  fecha_inicio  date,
  fecha_entrega date,
  prioridad     text,
  fee           numeric,
  enlaces       text,
  notas         text,
  comentarios   jsonb not null default '[]'::jsonb,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);
create index if not exists idx_proyectos_cliente on public.proyectos(cliente_id);
create trigger trg_proyectos_updated before update on public.proyectos
  for each row execute function public.set_updated_at();

-- ---------- 5. TAREAS ----------
create table if not exists public.tareas (
  id           uuid primary key default gen_random_uuid(),
  titulo       text not null,
  proyecto_id  uuid references public.proyectos(id) on delete cascade,
  estado       text,
  responsable  text,
  equipo       text,
  prioridad    text,
  fecha_limite date,
  estimacion   numeric,
  etiquetas    text,
  checklist    jsonb not null default '[]'::jsonb,
  depende_de   uuid references public.tareas(id) on delete set null,
  enlaces      text,
  notas        text,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now()
);
create index if not exists idx_tareas_proyecto on public.tareas(proyecto_id);
create trigger trg_tareas_updated before update on public.tareas
  for each row execute function public.set_updated_at();

-- ---------- 6. VISTAS GUARDADAS (compartidas por el equipo) ----------
create table if not exists public.saved_views (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid references public.profiles(id) on delete set null,
  name       text not null,
  config     jsonb not null default '{}'::jsonb,
  created_at timestamptz default now()
);

-- ---------- 7. CONFIG (automatizaciones · fila única compartida) ----------
create table if not exists public.app_config (
  id     int primary key default 1 check (id = 1),
  config jsonb not null default '{}'::jsonb
);
insert into public.app_config (id, config) values (1, '{}'::jsonb)
  on conflict (id) do nothing;

-- ============================================================
-- 8. ROW LEVEL SECURITY
--    Modelo de confianza de equipo: cualquier usuario autenticado
--    (= invitado) puede leer y escribir los datos de trabajo.
-- ============================================================
alter table public.profiles    enable row level security;
alter table public.clientes    enable row level security;
alter table public.proyectos   enable row level security;
alter table public.tareas      enable row level security;
alter table public.saved_views enable row level security;
alter table public.app_config  enable row level security;

-- Perfiles: todos los del equipo se ven; cada uno edita el suyo
create policy "perfiles_lectura"   on public.profiles for select to authenticated using (true);
create policy "perfiles_edito_mio" on public.profiles for update to authenticated using (auth.uid() = id);

-- Datos de trabajo: acceso total para el equipo autenticado
create policy "clientes_equipo"    on public.clientes    for all to authenticated using (true) with check (true);
create policy "proyectos_equipo"   on public.proyectos   for all to authenticated using (true) with check (true);
create policy "tareas_equipo"      on public.tareas      for all to authenticated using (true) with check (true);
create policy "vistas_equipo"      on public.saved_views for all to authenticated using (true) with check (true);
create policy "config_equipo"      on public.app_config  for all to authenticated using (true) with check (true);

-- ============================================================
-- 9. REALTIME (edición en vivo entre miembros) — opcional
-- ============================================================
alter publication supabase_realtime add table public.clientes;
alter publication supabase_realtime add table public.proyectos;
alter publication supabase_realtime add table public.tareas;

-- ============================================================
-- 10. STORAGE para adjuntos reales (ficheros) — opcional
--     Nota: límite de 50 MB por fichero en el plan gratuito.
-- ============================================================
insert into storage.buckets (id, name, public)
values ('adjuntos', 'adjuntos', false)
  on conflict (id) do nothing;

create policy "adjuntos_lee"    on storage.objects for select to authenticated using (bucket_id = 'adjuntos');
create policy "adjuntos_sube"   on storage.objects for insert to authenticated with check (bucket_id = 'adjuntos');
create policy "adjuntos_borra"  on storage.objects for delete to authenticated using (bucket_id = 'adjuntos');

-- ============================================================
-- LISTO. Tras ejecutar: invita a tu equipo en Authentication -> Users,
-- y copia Project URL + anon key (Settings -> API) para conectar la app.
-- ============================================================
