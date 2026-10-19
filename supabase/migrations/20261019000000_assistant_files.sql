-- Fichiers que l'app envoie à l'assistant (énoncés et corrigés PDF, fichiers
-- ajoutés), gardés dans un stockage **privé** : `<jeton haché>/<SHA-256>`.
--
-- Aucune politique : seule la fonction `mcp` (clé de service) y accède. Le
-- stockage est la seule source de vérité de ce qui est arrivé ; la fonction
-- l'efface à la déconnexion, quand l'app cesse d'annoncer un fichier, ou
-- quand le réglage « Fichiers et notes » est coupé.

insert into storage.buckets (id, name, public, file_size_limit)
values ('assistant-files', 'assistant-files', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = 10485760;
