import { ImageResponse } from "next/og";
import { SITE } from "./config";

export const alt = `${SITE.name} — ${SITE.tagline}`;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "80px 90px",
          background: "#0a0b0f",
          backgroundImage:
            "radial-gradient(circle at 78% 8%, #1b1e28 0%, #0a0b0f 60%)",
          color: "#f1f2f5",
          fontFamily: "sans-serif",
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", maxWidth: 700 }}>
          <div
            style={{
              fontSize: 26,
              color: "#b7bccb",
              fontWeight: 600,
              marginBottom: 18,
            }}
          >
            {`Menu-bar app · ${SITE.minMacOS}`}
          </div>
          <div
            style={{
              fontSize: 76,
              fontWeight: 800,
              letterSpacing: "-0.03em",
              lineHeight: 1.05,
            }}
          >
            {SITE.tagline}
          </div>
          <div style={{ fontSize: 30, color: "#9b9ea8", marginTop: 26 }}>
            Keep your Mac awake — lid shut — only while a long task runs.
          </div>
          <div style={{ fontSize: 28, color: "#d6d9df", marginTop: 40, fontWeight: 600 }}>
            {SITE.domain}
          </div>
        </div>
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            width: 300,
            height: 300,
            borderRadius: 66,
            background: "#17181d",
            backgroundImage:
              "radial-gradient(circle at 50% 30%, #26282f 0%, #101116 75%)",
            border: "1px solid #2a2c33",
            boxShadow: "0 0 90px 20px rgba(0,0,0,0.5)",
            flex: "none",
          }}
        >
          <div
            style={{
              width: 176,
              height: 176,
              borderRadius: "50%",
              backgroundImage:
                "radial-gradient(circle at 38% 34%, #ffffff 0%, #cfd3da 55%, #8f949e 100%)",
              boxShadow: "0 0 40px 8px rgba(214,217,223,0.28)",
            }}
          />
        </div>
      </div>
    ),
    size
  );
}
