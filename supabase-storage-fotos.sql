-- ============================================================
-- Armazenamento de fotos dos produtos (Supabase Storage)
--
-- Cria um "bucket" (pasta pública) chamado fotos-produtos, onde o
-- ERP vai subir as fotos dos itens. É público pra leitura (qualquer
-- pessoa vendo o site consegue ver a foto), mas só um usuário
-- logado E membro da empresa dona da pasta consegue enviar/trocar
-- arquivo — cada empresa só mexe na própria pasta (nome da pasta =
-- empresa_id), igual ao resto do sistema multi-empresa.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-produtos', 'fotos-produtos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

-- limpa políticas antigas (se existirem) pra recriar do zero
drop policy if exists "fotos-produtos: enviar (membros)" on storage.objects;
drop policy if exists "fotos-produtos: atualizar (membros)" on storage.objects;
drop policy if exists "fotos-produtos: apagar (membros)" on storage.objects;

-- só membro (logado) da empresa pode enviar foto na pasta da própria empresa
-- (a 1ª parte do caminho do arquivo tem que ser o empresa_id dele)
create policy "fotos-produtos: enviar (membros)"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'fotos-produtos'
  and erp_e_membro(((storage.foldername(name))[1])::uuid)
);

create policy "fotos-produtos: atualizar (membros)"
on storage.objects for update to authenticated
using (
  bucket_id = 'fotos-produtos'
  and erp_e_membro(((storage.foldername(name))[1])::uuid)
);

create policy "fotos-produtos: apagar (membros)"
on storage.objects for delete to authenticated
using (
  bucket_id = 'fotos-produtos'
  and erp_e_membro(((storage.foldername(name))[1])::uuid)
);

-- leitura: como o bucket é público, qualquer pessoa (inclusive
-- visitante anônimo do site de pedidos) já consegue ver as fotos
-- pela URL pública, sem precisar de política extra aqui.
