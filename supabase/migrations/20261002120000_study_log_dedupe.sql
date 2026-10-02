-- Temps d'étude des groupes : doublons purgés, et rendus impossibles.
--
-- L'app renvoyait à chaque synchronisation les agrégats journaliers des sept
-- derniers jours **en insertion simple** : les mêmes lignes s'empilaient
-- (1 107 lignes pour 27 journées réelles), et `group_leaderboard`, qui les
-- additionne, affichait 1 235 h sur sept jours.
--
-- On garde, pour chaque (membre, groupe, jour, cours, nature), la ligne la plus
-- longue — l'agrégat le plus récent, puisque la journée ne fait que grandir —
-- puis une contrainte d'unicité empêche tout retour. L'app remplace désormais
-- ses lignes de la fenêtre au lieu de les ajouter.

delete from public.study_log_public a
using public.study_log_public b
where a.user_id = b.user_id
  and a.group_id = b.group_id
  and a.started_at = b.started_at
  and a.course_code is not distinct from b.course_code
  and a.task_type is not distinct from b.task_type
  and (a.duration_seconds < b.duration_seconds
       or (a.duration_seconds = b.duration_seconds and a.ctid < b.ctid));

alter table public.study_log_public drop constraint if exists study_log_public_day_key;
alter table public.study_log_public add constraint study_log_public_day_key
  unique nulls not distinct (user_id, group_id, started_at, course_code, task_type);

notify pgrst, 'reload schema';
