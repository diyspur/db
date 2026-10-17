# Decisões de produto — clubes, diário e listas

## ADR-01 — Clubes

- Clube público permite entrada direta; clube privado exige convite.
- `user_clubs.owner_id` é a única autoridade. O papel `owner` na membership é reflexo.
- O owner não pode sair; deve transferir autoridade em uma evolução posterior ou arquivar o clube.
- Convites são direcionados a usuários já cadastrados por UUID validado no servidor; não há busca de e-mail nem envio automático nesta entrega.
- A criação usa UUID de requisição como chave de idempotência e RPC transacional.

## ADR-02 — Diário

- Todo registro nasce privado, mesmo quando contém spoiler.
- A primeira entrega não habilita compartilhamento editorial por clube: o banco remove a exposição de `club` sem `shared_club_id` válido.
- Páginas, percentual e minutos são opcionais; o sistema não inventa valores nem deduz conclusão/XP do texto.
- Anexos continuam dependentes do bucket privado já existente e de validação Storage em staging.

## ADR-07 — Listas

- A versão da lista funciona como controle otimista de concorrência.
- Reordenação deve ocorrer por RPC, bloqueando a linha da lista pai e validando o conjunto completo de itens.
- `unlisted` não é tratado como senha nem como compartilhamento seguro por slug.

## Gates antes de produção

- Aplicar a migration apenas em staging após reconciliar o histórico remoto.
- Regenerar `src/types/database.ts` depois do apply e substituir as fronteiras temporárias `as any` em actions/queries.
- Executar Auth/RLS com titular A, titular B, membro de clube privado, owner e usuário anônimo.
- Validar Storage, Realtime, concorrência e rollback; esta alteração não faz `db push` nem altera o Supabase remoto.

## ADR-08 — Grupo Oficial Único por Livro e Canais Permanentes

- Todo livro visível possui no máximo um grupo oficial (`user_clubs.kind = 'official'`, `official_book_id = books.id`), garantido por índice único parcial/total e `pg_advisory_xact_lock` em `ensure_official_book_group`.
- O grupo oficial nasce público, nunca pode ser tornado privado e cria os canais padrão `sem-spoilers` (`spoiler_policy = 'none'`) e `com-spoilers` (`spoiler_policy = 'whole_book'`).
- A exclusão da conta do criador inaugural promove o próximo moderador/membro elegível ou mantém `owner_id = NULL` sob tutela administrativa, sem excluir o grupo oficial.

## ADR-09 — Discussões por Capítulo, Vídeo e Consentimento de Spoilers

- Canais de capítulo (`kind = 'chapter'`) exigem que o capítulo esteja publicado e marcado como `read` pelo leitor.
- O diretório (`get_club_channel_directory`) nunca expõe o título real de capítulos futuros bloqueados (`Capítulo N (bloqueado)`).
- Canais com `spoiler_policy IN ('whole_book', 'chapter')` exigem aceite explícito na versão vigente (`club_channel_consents.rules_version`).

## ADR-10 — Estado Canônico de Leitura por Livro e Rankings

- `public.user_book_readings` é a fonte canônica de leitura por obra (`want_to_read`, `reading`, `read`, `dnf`) com controle otimista `version` e deduplicação por `request_id`.
- O backfill a partir de `user_progress` é conservador (`reading`), nunca marcando `read` automaticamente a partir de temporadas parciais.
- `public.v_book_reading_stats` expõe agregados por obra e `rank_position` via `dense_rank()`.

## ADR-11 — Encontros por Livro/Clube e Centro de Notificações no Header

- `public.meetings` possui `book_id NOT NULL`, `club_id` opcional e `chapter_id` opcional (`ON DELETE RESTRICT`), permitindo encontros gerais da obra ou do grupo.
- Notificações comunitárias são produzidas assincronamente via `private.community_notification_outbox` com payload neutro (sem trechos de mensagens com spoilers) e marcadas como lidas de forma idempotente por `mark_my_notifications_read`.

