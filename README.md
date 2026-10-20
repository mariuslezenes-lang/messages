# Messages — web app de messagerie (PWA + Supabase)

Texte, photos et messages vocaux, en temps réel, discussions à deux et groupes.
Un seul `index.html`, aucune étape de build.

## Tester tout de suite
Ouvre `index.html` : sans clés Supabase, l'appli tourne en **mode démo** (faux contacts qui répondent, tout reste dans le navigateur).

## Brancher Supabase
1. Crée un projet sur supabase.com.
2. **SQL Editor** → colle `schema.sql` → *Run*. Ça crée les tables, la sécurité RLS, le temps réel et le bucket `media`.
3. **Project Settings → API** : copie l'URL du projet et la clé `anon` / *publishable*, puis colle-les dans `CONFIG` en haut du script de `index.html`.
4. **Authentication → URL Configuration** : mets l'adresse de ton site (ex. `https://tonpseudo.github.io/messages/`) dans *Site URL* et *Redirect URLs*, pour que le lien de confirmation par e-mail revienne au bon endroit.
   Pour tester plus vite, tu peux désactiver *Confirm email* (Authentication → Providers → Email).

## Publier sur GitHub Pages
Pousse le dossier dans un dépôt → Settings → Pages → branche `main`, dossier `/`.
En HTTPS, le service worker s'active : sur iPhone « Partager → Sur l'écran d'accueil », sur Android « Installer l'application ».

## Fichiers
| Fichier | Rôle |
|---|---|
| `index.html` | Toute l'interface (CSS + JS), backend Supabase et backend démo |
| `schema.sql` | Base de données, RLS, fonctions `start_direct` / `create_group`, temps réel, stockage |
| `manifest.webmanifest`, `sw.js`, `icon-*.png` | Installation en PWA et cache hors ligne |

## Comment ça marche
- **Sécurité** : chaque requête passe par RLS ; on ne voit que les conversations dont on est membre (`is_member`). Le bucket `media` est privé, les fichiers sont servis par URL signée (1 h).
- **Temps réel** : abonnement `postgres_changes` sur `messages` (filtré par RLS) et sur ses propres adhésions (pour voir apparaître un groupe où l'on vient d'être ajouté).
- **Envoi** : l'ID du message est généré côté client → affichage instantané, puis confirmation serveur sans doublon.
- **Photos** : redimensionnées à 1600 px / JPEG 85 % avant l'envoi.
- **Vocaux** : `MediaRecorder` (WebM/Opus sur Chrome/Android, MP4/AAC sur Safari), 5 min max.
- **Non lus** : `last_read_at` par membre, comparé à `last_message_at` de la conversation.

## Pistes pour la suite
- Notifications push (Web Push + Edge Function)
- Pagination des anciens messages (aujourd'hui : 200 derniers)
- Photo de profil, indicateur « en train d'écrire » (Realtime Presence), accusés de lecture
