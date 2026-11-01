// Connection to the Supabase database.
// Find both values in Supabase: Project Settings → API (or "Connect" → App frameworks).
// The key here is the PUBLIC "anon" / "publishable" key – it is meant to be visible.
// NEVER put the "service_role" / "secret" key here.
window.SAKAL_CONFIG = {
  url: "",   // e.g. "https://abcdefghijkl.supabase.co"
  key: ""    // e.g. "sb_publishable_..." or the long "eyJ..." anon key
};
