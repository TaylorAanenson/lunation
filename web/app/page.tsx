import { SITE } from "./config";
import styles from "./page.module.css";

/* A moon-phase glyph drawn to match the SF Symbols `moonphase.*` the menu-bar
   app renders (see MoonPhase.swift): a thin limb ring that's always visible, with
   the illuminated portion filled behind a proper *elliptical* terminator — not a
   photographic disc with a sliding circular shadow. `frac` is the illuminated
   fraction (0 = new, 1 = full); `direction` picks the lit side, waxing on the
   right and waning on the left, the same as the SF symbols. */
function Moon({
  size = 120,
  frac = 1,
  glow = false,
  direction = "waxing",
}: {
  size?: number;
  frac?: number;
  glow?: boolean;
  direction?: "waxing" | "waning";
}) {
  const cx = 50;
  const cy = 50;
  const stroke = 5;
  const R = 40; // the limb ring's radius (stroke is centered on it)
  // The lit fill sits just inside the ring's inner edge so it never paints over
  // the stroke — the ring stays a clean, unbroken circle all the way around.
  const Rf = R - stroke / 2;
  const f = Math.max(0, Math.min(1, frac));
  // The terminator is a half-ellipse whose horizontal radius shrinks to 0 at the
  // quarter (straight edge) and grows back to Rf at new/full. Its curvature flips
  // between the crescent (bulges into the disc) and gibbous (bulges outward) sides.
  const rx = Rf * Math.abs(1 - 2 * f);
  const innerSweep = f < 0.5 ? 0 : 1;
  const top = `${cx} ${cy - Rf}`;
  const bot = `${cx} ${cy + Rf}`;
  // Lit region for a waxing (right-lit) moon: the right limb, then the terminator
  // back up. Waning mirrors it around the vertical axis to light the left side.
  const lit = `M ${top} A ${Rf} ${Rf} 0 0 1 ${bot} A ${rx} ${Rf} 0 0 ${innerSweep} ${top} Z`;
  const label =
    f <= 0.01
      ? "New moon"
      : f >= 0.99
        ? "Full moon"
        : `${direction === "waxing" ? "Waxing" : "Waning"} ${
            f < 0.5 ? "crescent" : f > 0.5 ? "gibbous" : "quarter"
          } moon`;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 100 100"
      role="img"
      aria-label={label}
      className={glow ? styles.moonGlow : undefined}
    >
      {/* the always-visible limb ring (the unlit edge of the disc) */}
      <circle cx={cx} cy={cy} r={R} fill="none" stroke="#7f7f7f" strokeWidth={stroke} strokeOpacity="0.7" />
      {/* the illuminated portion; mirror it for the waning (left-lit) half */}
      <path
        d={lit}
        fill="#b8bcc4"
        transform={direction === "waning" ? `translate(${2 * cx} 0) scale(-1 1)` : undefined}
      />
    </svg>
  );
}

/* The real macOS app icon (silver disc on a graphite squircle). Rounded corners
   are baked into the PNG's alpha, so no extra clipping is needed. */
function AppIcon({ size = 200, glow = false }: { size?: number; glow?: boolean }) {
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src="/app-icon.png"
      width={size}
      height={size}
      alt="Lunation app icon"
      className={glow ? styles.appIconGlow : styles.appIcon}
    />
  );
}

/* A full cycle for the strip: waxes up to full (task spinning up), then wanes
   back down (winding down). The waning half lights the left side, like the SF
   symbols, so both lit sides are shown. */
const PHASES: { frac: number; dir: "waxing" | "waning" }[] = [
  { frac: 0, dir: "waxing" },
  { frac: 0.25, dir: "waxing" },
  { frac: 0.5, dir: "waxing" },
  { frac: 0.75, dir: "waxing" },
  { frac: 1, dir: "waxing" },
  { frac: 0.75, dir: "waning" },
  { frac: 0.5, dir: "waning" },
  { frac: 0.25, dir: "waning" },
  { frac: 0, dir: "waning" },
];

export default function Home() {
  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: SITE.name,
    description: SITE.description,
    applicationCategory: "UtilitiesApplication",
    operatingSystem: "macOS 26+",
    softwareVersion: SITE.version,
    url: SITE.url,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  };

  return (
    <main className={styles.main}>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <div className={styles.stars} aria-hidden />

      {/* ---- Nav ---- */}
      <header className={styles.nav}>
        <a className={styles.brand} href="/">
          <AppIcon size={30} />
          <span>{SITE.name}</span>
        </a>
        <nav className={styles.navLinks}>
          <a href="#how">How it works</a>
          <a href="#safety">Safety</a>
          <a href={SITE.githubUrl}>GitHub</a>
        </nav>
      </header>

      {/* ---- Hero ---- */}
      <section className={styles.hero}>
        <div className={styles.heroText}>
          <p className={styles.eyebrow}>Menu-bar app · {SITE.minMacOS}</p>
          <h1 className={styles.h1}>{SITE.tagline}</h1>
          <p className={styles.lede}>{SITE.description}</p>
          <div className={styles.ctaRow}>
            <a className={styles.primary} href={SITE.downloadUrl}>
              <DownloadGlyph />
              Download for macOS
            </a>
            <a className={styles.secondary} href={SITE.githubUrl}>
              View on GitHub
            </a>
          </div>
          <p className={styles.fineprint}>
            Free · notarized · Apple Silicon · v{SITE.version}
          </p>
        </div>
        <div className={styles.heroArt} aria-hidden>
          <div className={styles.heroIcon}>
            <AppIcon size={210} glow />
          </div>
          <div className={styles.mbOverlap}>
            <MenuBarMock />
          </div>
        </div>
      </section>

      {/* ---- The problem / why ---- */}
      <section className={styles.band}>
        <p className={styles.bandLead}>
          <strong>caffeinate can&apos;t keep a Mac awake with the lid closed.</strong>{" "}
          Neither can the usual power assertions — lid-close sleep is governed
          separately. Lunation flips the one switch that actually works, only while
          your task is running, and flips it back the moment it&apos;s done.
        </p>
      </section>

      {/* ---- Features ---- */}
      <section className={styles.features}>
        <Feature
          title="Lid-closed, actually"
          body="Shut the laptop and walk away. Lunation uses the one lever that defeats clamshell sleep, so a long run won't die the moment you close the lid."
          frac={1}
        />
        <Feature
          title="Knows when you're working"
          body="An ambient helper watches for real Claude Code activity through its own hooks — a lightweight heartbeat as the agent works — and only holds sleep off while work is actually happening. No CPU guessing, so an idle desktop app never fools it."
          frac={0.5}
        />
        <Feature
          title="Sleeps itself back"
          body="Once the task goes quiet past a grace period, normal sleep comes back automatically — and it's restored just as reliably on quit, crash, and restart, so your Mac is never stranded awake."
          frac={0}
        />
      </section>

      {/* ---- How it works ---- */}
      <section id="how" className={styles.how}>
        <h2 className={styles.h2}>How it works</h2>
        <ol className={styles.steps}>
          <li>
            <span className={styles.stepNum}>1</span>
            <div>
              <h3>Install the helper</h3>
              <p>
                One click registers a small background helper that does the
                privileged work. The app itself never needs to run your tasks as
                root.
              </p>
            </div>
          </li>
          <li>
            <span className={styles.stepNum}>2</span>
            <div>
              <h3>Start a long task &amp; close the lid</h3>
              <p>
                Kick off a Claude Code session and it&apos;s detected
                automatically. Running something else — a build, a test suite?
                Flip on <em>Force awake</em> from the menu bar first. Either way,
                shut the laptop and go.
              </p>
            </div>
          </li>
          <li>
            <span className={styles.stepNum}>3</span>
            <div>
              <h3>It stays awake, then sleeps</h3>
              <p>
                The menu bar shows live status — <em>Idle</em>,{" "}
                <em>Claude Code active</em>, or <em>Forced awake</em>. When the
                work finishes, sleep comes back on its own.
              </p>
            </div>
          </li>
        </ol>

        <div className={styles.phaseStrip} aria-hidden>
          {PHASES.map((p, i) => (
            <Moon key={i} size={44} frac={p.frac} direction={p.dir} />
          ))}
        </div>
        <p className={styles.phaseCaption}>
          The moon waxes as your task spins up, and wanes as it winds down.
        </p>
      </section>

      {/* ---- Safety ---- */}
      <section id="safety" className={styles.safety}>
        <div className={styles.safetyInner}>
          <h2 className={styles.h2}>Thermal &amp; battery aware</h2>
          <p>
            A closed Mac under load can&apos;t shed heat, so Lunation is cautious by
            design. It refuses to disable sleep on battery by default, and if the
            chip starts thermally throttling it forces sleep to protect the
            hardware — even over a manual override.
          </p>
          <p className={styles.warn}>
            Keep your Mac on a ventilated surface while it works. Never run it shut
            inside a bag.
          </p>
        </div>
      </section>

      {/* ---- FAQ ---- */}
      <section id="faq" className={styles.faq}>
        <h2 className={styles.h2}>Questions</h2>
        <div className={styles.faqList}>
          {FAQ.map(({ q, a }) => (
            <details key={q} className={styles.faqItem}>
              <summary>{q}</summary>
              <p>{a}</p>
            </details>
          ))}
        </div>
      </section>

      {/* ---- Final CTA ---- */}
      <section className={styles.finalCta}>
        <AppIcon size={80} glow />
        <h2 className={styles.h2}>Walk away mid-run.</h2>
        <p>Let the long ones finish with the lid shut.</p>
        <a className={styles.primary} href={SITE.downloadUrl}>
          <DownloadGlyph />
          Download for macOS
        </a>
        <p className={styles.fineprint}>{SITE.minMacOS} · notarized</p>
      </section>

      {/* ---- Footer ---- */}
      <footer className={styles.footer}>
        <span>
          {SITE.name} · {SITE.domain}
        </span>
        <span className={styles.footerLinks}>
          <a href={SITE.githubUrl}>GitHub</a>
          <a href={SITE.downloadUrl}>Download</a>
        </span>
      </footer>
    </main>
  );
}

/* A CSS recreation of the real menu-bar dropdown (see MenuBarView.swift):
   live status and the force-awake duration pills. */
function MenuBarMock() {
  return (
    <div className={styles.mbWrap}>
      <div className={styles.mbBar}>
        <Moon size={16} frac={1} />
      </div>
      <div className={styles.mbPanel}>
        <div className={styles.mbStatus}>
          <span className={styles.mbDot} />
          <div>
            <p className={styles.mbStrong}>Claude Code active</p>
          </div>
        </div>
        <div className={styles.mbDivider} />
        <p className={styles.mbLabel}>Force awake for</p>
        <div className={styles.mbPills}>
          <span>1h</span>
          <span>2h</span>
          <span>8h</span>
          <span>◷</span>
          <span>∞</span>
        </div>
        <div className={styles.mbDivider} />
        <p className={styles.mbRow}>Settings…</p>
        <p className={styles.mbRow}>Quit</p>
      </div>
    </div>
  );
}

const FAQ = [
  {
    q: "Can it really keep the Mac awake with the lid closed?",
    a: "Yes. macOS governs clamshell sleep separately, so caffeinate and the usual power assertions can't override it — Lunation flips the one system lever that does (pmset disablesleep), and flips it back when your task is done.",
  },
  {
    q: "How is it different from caffeinate or Amphetamine?",
    a: "Those keep the display or system awake while the lid is open, and they stay on until you turn them off. Lunation works with the lid shut and is automatic: it detects when your task is actually running and restores normal sleep once it goes idle.",
  },
  {
    q: "Will my Mac overheat?",
    a: "A closed Mac under load can't shed heat, so Lunation is conservative: it refuses to disable sleep on battery by default, and forces sleep if the chip starts thermally throttling — even over a manual override. Keep it on a ventilated surface, never shut inside a bag.",
  },
  {
    q: "Does it need admin or run my tasks as root?",
    a: "No. The privileged work lives in a small background helper you authorize once, and the app never runs your tasks as root. Sleep is restored defensively — on quit, crash, and restart — so you're never left with it disabled.",
  },
  {
    q: "What does it work with?",
    a: "Claude Code sessions are detected automatically — the helper sees the CLI's activity through its hooks and holds sleep off while it works. For any other long, unattended run — a build, a test suite, a data job — flip on Force awake from the menu bar for a set duration (1h, 2h, 8h, until morning, or indefinitely), and it reverts on its own.",
  },
  {
    q: "Is it on the App Store?",
    a: "No — the mechanism it relies on isn't compatible with App Store sandboxing. It's distributed as a notarized download, outside the App Store.",
  },
];

function Feature({ title, body, frac }: { title: string; body: string; frac: number }) {
  return (
    <article className={styles.feature}>
      <div className={styles.featureMoon} aria-hidden>
        <Moon size={56} frac={frac} />
      </div>
      <h3>{title}</h3>
      <p>{body}</p>
    </article>
  );
}

function DownloadGlyph() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden>
      <path
        d="M8 1v8m0 0L5 6m3 3 3-3M2 11v2a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-2"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
