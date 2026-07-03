import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Pin the file-tracing root to this app so a stray lockfile elsewhere on the
  // machine can't be inferred as the workspace root (keeps Vercel traces correct).
  outputFileTracingRoot: __dirname,
  // Clean download URL on our own domain that redirects to the newest GitHub
  // Release asset. 307 (permanent: false) so we can repoint it later without
  // browsers caching it forever. Asset must be named Lunation.dmg.
  async redirects() {
    return [
      {
        source: "/download",
        destination:
          "https://github.com/tayloraanenson/lunation/releases/latest/download/Lunation.dmg",
        permanent: false,
      },
    ];
  },
};

export default nextConfig;
