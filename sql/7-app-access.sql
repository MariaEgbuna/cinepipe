-- ╔══════════════════════════════════════════════════════════════╗
-- ║  7 - App Access                                              ║
-- ║  Who may read the app views                                  ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUN ON        Supabase only. The roles anon and             ║
-- ║                authenticated do not exist on your local      ║
-- ║                database.                                     ║
-- ║  STAGE 1       The website has no login yet, so it reads as  ║
-- ║                anon, the role behind the public key. Use     ║
-- ║                this on your own computer only. Do NOT put    ║
-- ║                the site on Vercel until Stage 2 has removed  ║
-- ║                the anon access.                              ║
-- ║  STAGE 2       After login is built, anon loses access and   ║
-- ║                only authenticated (you, logged in) can read. ║
-- ║  ALSO NEEDED   Add app to the exposed schemas in the         ║
-- ║                Supabase API settings, or the website cannot  ║
-- ║                see it.                                       ║
-- ╚══════════════════════════════════════════════════════════════╝

GRANT USAGE ON SCHEMA app TO anon, authenticated;

GRANT SELECT ON
    app.now_watching_series,
    app.now_watching_movies,
    app.library_series,
    app.library_movies,
    app.rewatch_movies,
    app.rewatch_series,
    app.rewatch_seasons
TO anon, authenticated;
