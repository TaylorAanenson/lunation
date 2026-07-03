// Central place for the bits that change between now and launch.
export const SITE = {
  name: "Lunation",
  domain: "lunation.dev",
  url: "https://lunation.dev",
  tagline: "Close the lid. Let it finish.",
  description:
    "Lunation keeps your Mac awake — even with the lid shut — for exactly as long " +
    "as your task runs, then lets it sleep again. Built for unattended " +
    "Claude Code and build runs.",
  version: "0.1",
  minMacOS: "macOS 26+",
  // /download redirects to the latest GitHub Release asset (see next.config.mjs),
  // so this stays valid across releases as long as the asset is named Lunation.dmg.
  downloadUrl: "/download",
  githubUrl: "https://github.com/tayloraanenson/lunation",
};
