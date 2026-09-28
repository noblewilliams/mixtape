import { useEffect, useRef, useState } from "react";
import { motion } from "motion/react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { moments, demoTracks } from "./content";
import {
  useDemoConversation,
  typedText,
  TURN_DURATION,
} from "./useDemoConversation";
import { Arrow } from "./Arrow";
import "./demo.css";

gsap.registerPlugin(ScrollTrigger);
const steps = [
  { title: "Start with a feeling.", copy: "Tell your DJ what’s on your mind." },
  {
    title: "Make it yours.",
    copy: "A little slower. More familiar. Just ask.",
  },
  {
    title: "Press play. Or keep it.",
    copy: "Play your mix or save it as a playlist.",
  },
];

function TypedMessage({
  text,
  elapsed,
  start,
  duration,
}: {
  text: string;
  elapsed: number;
  start: number;
  duration: number;
}) {
  const revealed = typedText(text, elapsed, start, duration).length;
  return (
    <>
      <span className="sr-only">{text}</span>
      <span aria-hidden="true">
        {Array.from(text).map((letter, index) => (
          <span
            key={index}
            style={{ visibility: index < revealed ? "visible" : "hidden" }}
          >
            {letter}
          </span>
        ))}
      </span>
    </>
  );
}

export function MixDemo({
  moment,
  still,
  appUrl,
}: {
  moment: number;
  still: boolean;
  appUrl: string;
}) {
  const [step, setStep] = useState(0);
  const [fits, setFits] = useState(true);
  const [stickyTop, setStickyTop] = useState(24);
  const runway = useRef<HTMLDivElement>(null);
  const sticky = useRef<HTMLDivElement>(null);
  const trigger = useRef<ScrollTrigger | null>(null);
  const selected = moments[moment];
  const [visible, setVisible] = useState(false);
  const conversation = useRef<HTMLDivElement>(null);
  const elapsed = useDemoConversation(step, still, visible);
  const firstReady = elapsed[0] >= TURN_DURATION;
  const secondReady = elapsed[1] >= TURN_DURATION;
  const songs = step > 0 && secondReady ? selected.refined : selected.songs;

  useEffect(() => {
    if (!sticky.current) return;
    const observer = new IntersectionObserver(
      ([entry]) => setVisible(entry.isIntersecting),
      { threshold: 0.5 },
    );
    observer.observe(sticky.current);
    return () => observer.disconnect();
  }, []);
  const showFollowUp = step >= 1 && firstReady;
  useEffect(() => {
    const element = conversation.current;
    if (element)
      element.scrollTo({
        top: showFollowUp ? element.scrollHeight : 0,
        behavior: still ? "instant" : "smooth",
      });
  }, [showFollowUp, still]);

  useEffect(() => {
    if (!sticky.current) return;
    const measure = () => {
      const height = sticky.current!.offsetHeight;
      setFits(height <= window.innerHeight - 48);
      setStickyTop(Math.max(24, (window.innerHeight - height) / 2));
    };
    const observer = new ResizeObserver(measure);
    observer.observe(sticky.current);
    window.addEventListener("resize", measure);
    measure();
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, []);

  useEffect(() => {
    if (still || !fits || !runway.current || !sticky.current) return;
    // Use the actual sticky height so all three steps fit on short screens too.
    const scroll = ScrollTrigger.create({
      trigger: runway.current,
      start: () => `top ${stickyTop}px`,
      end: () =>
        `+=${Math.max(1, runway.current!.offsetHeight - sticky.current!.offsetHeight)}`,
      invalidateOnRefresh: true,
      onUpdate: (self) =>
        setStep((previous) => {
          // Small dead bands prevent trackpad jitter from toggling adjacent steps.
          if (self.progress >= 0.72) return 2;
          if (self.progress <= 0.3) return 0;
          if (previous === 2 && self.progress >= 0.65) return 2;
          if (previous === 0 && self.progress <= 0.37) return 0;
          return 1;
        }),
    });
    trigger.current = scroll;
    const resize = new ResizeObserver(() => scroll.refresh());
    resize.observe(sticky.current);
    return () => {
      resize.disconnect();
      scroll.kill();
      trigger.current = null;
    };
  }, [still, fits, stickyTop]);

  function chooseStep(index: number) {
    const scroll = trigger.current;
    if (!scroll) setStep(index);
    if (scroll)
      window.scrollTo({
        top: scroll.start + (scroll.end - scroll.start) * ((index + 0.5) / 3),
        behavior: "smooth",
      });
  }

  return (
    <div
      ref={runway}
      className={`demo-runway ${still || !fits ? "demo-static" : ""}`}
    >
      <div
        ref={sticky}
        className="demo-sticky"
        style={{ top: still || !fits ? undefined : stickyTop }}
      >
        <div className="section-heading">
          <h2 id="demo-title">
            From a feeling
            <br />
            to a mix.
          </h2>
        </div>
        <div className="demo-shell">
          <div
            className="demo-progress"
            style={{ transform: `scaleX(${(step + 1) / 3})` }}
          />
          <div className="demo-steps" aria-label="Explore how a mix works">
            {steps.map((item, index) => (
              <button
                className={`demo-step ${step === index ? "step-active" : ""}`}
                key={item.title}
                aria-label={`0${index + 1} ${item.title}`}
                aria-pressed={step === index}
                onClick={() => chooseStep(index)}
              >
                <span className="step-number">0{index + 1}</span>
                <span>
                  <strong>{item.title}</strong>
                  <span className="step-copy">{item.copy}</span>
                </span>
              </button>
            ))}
          </div>
          <div
            className="demo-stage ambient"
            aria-label="Sample mix demonstration with illustrative songs"
          >
            <div className="demo-stage-content">
              <div
                className="demo-conversation conversation-history"
                ref={conversation}
                aria-label="Example conversation"
              >
                {[0, 1]
                  .filter((turn) => turn === 0 || (step >= 1 && firstReady))
                  .map((turn) => {
                    const prompt =
                      turn === 0 ? selected.prompt : "A little more upbeat.";
                    const reply =
                      turn === 0
                        ? "A little company for the road."
                        : "Same feeling. A little more lift.";
                    const time = elapsed[turn];
                    return (
                      <div className="demo-turn" key={turn}>
                        <p className="sample-prompt">
                          <TypedMessage
                            text={prompt}
                            elapsed={time}
                            start={0}
                            duration={1200}
                          />
                        </p>
                        <div className="demo-response-slot">
                          {time >= 1200 && time < 2100 && (
                            <div
                              className="demo-thinking"
                              role="status"
                              aria-label="DJ is thinking"
                            >
                              <i />
                              <i />
                              <i />
                            </div>
                          )}
                          <div
                            className="sample-reply"
                            style={{
                              visibility: time >= 2100 ? "visible" : "hidden",
                            }}
                          >
                            <p>
                              <TypedMessage
                                text={reply}
                                elapsed={time}
                                start={2100}
                                duration={800}
                              />
                            </p>
                          </div>
                        </div>
                      </div>
                    );
                  })}
              </div>
              <motion.div
                className="sample-mix"
                initial={false}
                animate={{
                  opacity: firstReady ? 1 : 0,
                  y: firstReady || still ? 0 : 10,
                }}
                aria-hidden={!firstReady}
                inert={!firstReady}
              >
                <div className="sample-mix-heading">
                  <h3>{selected.name}</h3>
                </div>
                <ol
                  className="sample-tracks"
                  aria-live="polite"
                  aria-label="Example songs"
                >
                  {songs.map((song, index) => (
                    <motion.li
                      key={song}
                      layout={still ? false : "position"}
                      transition={
                        still
                          ? { duration: 0 }
                          : { type: "spring", stiffness: 220, damping: 30 }
                      }
                      initial={still ? false : { opacity: 0 }}
                      animate={{ opacity: 1 }}
                    >
                      <span className="track-number">{index + 1}</span>
                      <img
                        className="track-cover"
                        src={demoTracks[song].artwork}
                        alt=""
                        width="34"
                        height="34"
                      />
                      <span className="sample-song">
                        {song}
                        <small>{demoTracks[song].artist}</small>
                      </span>
                      <span className="track-duration">
                        {demoTracks[song].duration}
                      </span>
                    </motion.li>
                  ))}
                </ol>
              </motion.div>
              <div className="demo-actions">
                {step === 2 && secondReady && (
                  <>
                    <a
                      className="demo-start"
                      href={appUrl}
                      title="Open Mixtape to play your own mix"
                    >
                      Play mix <Arrow />
                    </a>
                    <a
                      className="demo-start demo-save"
                      href={appUrl}
                      title="Open Mixtape to create your own playlist"
                    >
                      Create playlist <Arrow />
                    </a>
                  </>
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
