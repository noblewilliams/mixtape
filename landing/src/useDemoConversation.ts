import { useEffect, useState } from "react";

export const TURN_DURATION = 3200;
export function useDemoConversation(
  step: number,
  still: boolean,
  visible: boolean,
) {
  const [elapsed, setElapsed] = useState([0, 0]);
  const complete =
    elapsed[0] >= TURN_DURATION && (step < 1 || elapsed[1] >= TURN_DURATION);
  useEffect(() => {
    if (still || !visible || complete) return;
    const timer = window.setInterval(
      () =>
        setElapsed((previous) => {
          const turn =
            previous[0] < TURN_DURATION
              ? 0
              : step >= 1 && previous[1] < TURN_DURATION
                ? 1
                : -1;
          if (turn < 0) return previous;
          const next = [...previous];
          next[turn] = Math.min(TURN_DURATION, next[turn] + 40);
          return next;
        }),
      40,
    );
    return () => window.clearInterval(timer);
  }, [step, still, visible, complete]);
  return still ? [TURN_DURATION, step >= 1 ? TURN_DURATION : 0] : elapsed;
}

export function typedText(
  text: string,
  elapsed: number,
  start: number,
  duration: number,
) {
  return text.slice(
    0,
    Math.floor(
      text.length * Math.min(1, Math.max(0, (elapsed - start) / duration)),
    ),
  );
}
