import { FooterCloset } from "./FooterCloset";
import { Arrow } from "./Arrow";
import { useEffect, useRef, useState } from "react";
import {
  AnimatePresence,
  motion,
  MotionConfig,
  useReducedMotion,
} from "motion/react";
import { moments, questions } from "./content";
import { Tape } from "./Tape";
import { usePageMotion } from "./usePageMotion";
import { MixDemo } from "./MixDemo";

const APP_URL = import.meta.env.VITE_APP_URL || "/app/";
const DOWNLOAD_URL = import.meta.env.VITE_DOWNLOAD_URL || "";

function AppleMark() {
  return (
    <svg className="apple-mark" viewBox="7 5 12 15" aria-hidden="true">
      <path
        fill="currentColor"
        d="M16.71 12.74c.02 2.15 1.89 2.87 1.91 2.88-.02.05-.3 1.02-.98 2.03-.59.87-1.21 1.73-2.18 1.75-.95.02-1.26-.57-2.35-.57s-1.43.55-2.33.59c-.94.03-1.65-.94-2.25-1.8-1.22-1.77-2.15-5-.9-7.18a3.5 3.5 0 0 1 2.98-1.81c.93-.02 1.81.63 2.35.63.54 0 1.56-.78 2.63-.66.45.02 1.71.18 2.52 1.37-.07.04-1.5.88-1.4 2.77ZM14.89 7.47c.49-.6.83-1.43.74-2.26-.72.03-1.59.48-2.1 1.08-.46.53-.86 1.38-.75 2.19.8.06 1.62-.41 2.11-1.01Z"
      />
    </svg>
  );
}

function SpotifyMark() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="11" fill="currentColor" />
      <g
        fill="none"
        stroke="var(--paper)"
        strokeWidth="1.7"
        strokeLinecap="round"
      >
        <path d="M6 9c4-1.4 8-1.1 12 1M7 12.5c3.5-1 6.5-.7 10 1M8 16c2.8-.7 5.2-.4 8 1" />
      </g>
    </svg>
  );
}

function Wordmark() {
  return (
    <a className="wordmark" href="#top" aria-label="Mixtape home">
      <img src="/favicon.svg" alt="" width="32" height="24" />
      <span>mixtape</span>
    </a>
  );
}

function Sleeve({ index = 0 }: { index?: number }) {
  return (
    <div className={`sleeve sleeve-${index % 3}`} aria-hidden="true">
      <span />
      <i />
    </div>
  );
}

function Faq({ still }: { still: boolean }) {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <div className="faq-list">
      {questions.map((item, index) => (
        <article
          className={`faq-item ${open === index ? "faq-open" : ""}`}
          key={item.question}
        >
          <h3>
            <button
              aria-expanded={open === index}
              aria-controls={`answer-${index}`}
              onClick={() => setOpen(open === index ? null : index)}
            >
              {item.question}
              <span aria-hidden="true">{open === index ? "−" : "+"}</span>
            </button>
          </h3>
          <motion.div
            id={`answer-${index}`}
            className="faq-answer"
            inert={open !== index}
            aria-hidden={open !== index}
            initial={false}
            animate={{
              height: open === index ? "auto" : 0,
              opacity: open === index ? 1 : 0,
            }}
            transition={{ duration: still ? 0 : 0.3 }}
          >
            <p>{item.answer}</p>
          </motion.div>
        </article>
      ))}
    </div>
  );
}

function Download({
  url,
  onUnavailable,
  className = "button button-light",
}: {
  url: string;
  onUnavailable: () => void;
  className?: string;
}) {
  const label = (
    <>
      <AppleMark />
      Download the app
    </>
  );
  return url ? (
    <a className={`${className} button-download`} href={url}>
      {label}
    </a>
  ) : (
    <button className={`${className} button-download`} onClick={onUnavailable}>
      {label}
    </button>
  );
}

export function App({ downloadUrl = DOWNLOAD_URL }: { downloadUrl?: string }) {
  const root = useRef<HTMLDivElement>(null);
  const downloadDialog = useRef<HTMLDialogElement>(null);
  const reduced = useReducedMotion();
  const moment = 0;
  const still = Boolean(reduced);
  const selected = moments[moment];
  usePageMotion(root, !still);

  useEffect(() => {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) =>
        entry.target.classList.toggle("in-view", entry.isIntersecting),
      );
    });
    root.current
      ?.querySelectorAll(".ambient")
      .forEach((node) => observer.observe(node));
    return () => observer.disconnect();
  }, []);

  const downloadProps = {
    url: downloadUrl,
    onUnavailable: () => downloadDialog.current?.showModal(),
  };

  return (
    <MotionConfig
      reducedMotion={still ? "always" : "never"}
      transition={{ duration: still ? 0 : 0.35 }}
    >
      <div
        ref={root}
        className={`landing ${still ? "motion-paused" : ""}`}
        id="top"
      >
        <a className="skip-link" href="#main">
          Skip to content
        </a>
        <main id="main">
          <section className="hero" aria-labelledby="hero-title">
            <div className="hero-copy">
              <Wordmark />
              <div className="intro-line">
                <span className="prism-chip" aria-hidden="true" />
                Good taste. Meet good timing.
              </div>
              <h1 id="hero-title">
                What should
                <br />
                this moment
                <br />
                sound like?
              </h1>
              <p className="hero-description">
                Tell your DJ the mood. Find your next mix.
              </p>
              <div className="hero-actions">
                <a className="button button-dark" href={APP_URL}>
                  Open in browser <Arrow />
                </a>
                <div className="download-group">
                  <Download {...downloadProps} />
                  <small>Recommended for Apple Music library sync</small>
                </div>
              </div>
            </div>
            <div className="hero-art ambient">
              <img
                className="hero-photo"
                src="/images/prism-cassette.jpg"
                alt="A translucent cassette illuminated by a beam of rainbow light"
                width="1536"
                height="1536"
                fetchPriority="high"
              />
              <div className="hero-art-top">
                <span>Made for the way you feel.</span>
              </div>
              <div className="hero-caption">
                <span className="equalizer" aria-hidden="true">
                  <i />
                  <i />
                  <i />
                  <i />
                </span>
                <div>
                  <small>A mix for your moment</small>
                  <AnimatePresence mode="wait" initial={false}>
                    <motion.p
                      key={selected.name}
                      initial={{ opacity: 0, y: still ? 0 : 8 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={{ opacity: 0, y: still ? 0 : -8 }}
                    >
                      {selected.name}
                    </motion.p>
                  </AnimatePresence>
                </div>
                <span className="hero-side">Side A</span>
              </div>
            </div>
          </section>

          <section
            className="demo-section section wrap"
            id="how-it-works"
            aria-labelledby="demo-title"
          >
            <MixDemo moment={moment} still={still} appUrl={APP_URL} />
          </section>

          <section
            className="section taste-section wrap"
            aria-labelledby="taste-title"
          >
            <div className="section-heading">
              <h2 id="taste-title">
                Your taste is
                <br />
                the starting point.
              </h2>
            </div>
            <div className="feature-grid import-grid" id="your-music">
              <article className="feature import-card import-apple">
                <div className="feature-copy">
                  <h3>Your Apple Music library.</h3>
                  <p>
                    Sync your favourites, playlists and play counts from the
                    app.
                  </p>
                </div>
                <div className="import-art library-art">
                  <div className="sleeve-stack">
                    <Sleeve />
                    <Sleeve index={1} />
                    <Sleeve index={2} />
                  </div>
                  <div className="feature-tape">
                    <Tape title="On repeat" />
                  </div>
                </div>
              </article>
              <article className="feature import-card import-export">
                <div className="feature-copy">
                  <h3>Bring your Spotify playlists.</h3>
                  <p>
                    Drop in an Exportify file. Give your DJ a place to start.
                  </p>
                </div>
                <div className="import-art export-art" aria-hidden="true">
                  <div className="file-sheet">
                    <SpotifyMark />
                    <span>favourites.csv</span>
                    <i />
                    <i />
                    <i />
                    <i />
                  </div>
                  <span className="file-seal">CSV</span>
                </div>
              </article>
              <article className="feature import-card import-history">
                <div className="feature-copy">
                  <h3>Go beyond your favourites.</h3>
                  <p>
                    Request your listening history from Spotify or Apple. More
                    history, more context.
                  </p>
                  <small>
                    Spotify history import available. Apple archive import
                    coming next.
                  </small>
                </div>
                <div className="import-art archive-art" aria-hidden="true">
                  <div className="archive-sheet">
                    2024
                    <span />
                  </div>
                  <div className="archive-sheet">
                    2025
                    <span />
                  </div>
                  <div className="archive-sheet">
                    2026
                    <span />
                  </div>
                </div>
              </article>
              <article className="feature import-card import-memory">
                <div className="feature-copy">
                  <h3>A DJ that remembers.</h3>
                  <p>
                    Your preferences, in your words. Keep or forget any note.
                  </p>
                </div>
                <div className="import-art memory-art">
                  <span className="memory-sun" aria-hidden="true" />
                  <div className="memory-note">
                    <span className="note-dot" />A note for next time
                    <p>
                      “More soul.
                      <br />
                      Less of the obvious.”
                    </p>
                    <span className="note-saved">Remembered.</span>
                  </div>
                </div>
              </article>
            </div>
          </section>

          <div
            className="prism-band"
            aria-label="Less searching. More feeling."
          >
            <p>
              Less searching.
              <br />
              More feeling.
            </p>
            <span className="band-record" aria-hidden="true">
              <i />
            </span>
          </div>

          <section
            className="section faq-section wrap"
            id="questions"
            aria-labelledby="faq-title"
          >
            <div className="faq-heading">
              <h2 id="faq-title">
                Before you
                <br />
                press play.
              </h2>

              <span className="faq-flower" aria-hidden="true">
                ✳
              </span>
            </div>
            <Faq still={still} />
          </section>
        </main>
        <footer className="closing" aria-labelledby="closing-title">
          <div className="closing-glow" aria-hidden="true" />
          <div className="closing-content">
            <h2 id="closing-title">
              Make a little room
              <br />
              for music.
            </h2>
            <div className="closing-actions">
              <a className="button button-dark" href={APP_URL}>
                Open in browser <Arrow />
              </a>
              <div className="download-group">
                <Download {...downloadProps} className="button button-glass" />
                <small>Recommended for Apple Music library sync</small>
              </div>
            </div>
          </div>
          <div className="footer-bottom wrap">
            <Wordmark />
            <nav className="footer-nav" aria-label="Footer navigation">
              <a href="#how-it-works">How it works</a>
              <a href="#your-music">Your library</a>
              <a href="#questions">Questions</a>

              <a href="#top">Back to top</a>
            </nav>
          </div>
          <FooterCloset />
        </footer>

        <dialog
          ref={downloadDialog}
          className="download-dialog"
          aria-labelledby="download-title"
          onClick={(event) => {
            if (event.target === event.currentTarget)
              downloadDialog.current?.close();
          }}
        >
          <button
            className="dialog-close"
            onClick={() => downloadDialog.current?.close()}
            aria-label="Close"
          >
            ×
          </button>
          <img src="/favicon.svg" alt="" width="60" />
          <h2 id="download-title">
            A little closer
            <br />
            to your music.
          </h2>
          <p>
            We recommend the app for Apple Music library sync. The download link
            isn’t available yet — you can get started in your browser.
          </p>
          <a className="button button-dark" href={APP_URL}>
            Open in browser <Arrow />
          </a>
        </dialog>
      </div>
    </MotionConfig>
  );
}
