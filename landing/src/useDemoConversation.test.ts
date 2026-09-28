import { act, renderHook } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { useDemoConversation, TURN_DURATION } from "./useDemoConversation";
afterEach(() => vi.useRealTimers());
it("waits until visible, then queues both turns without restarting when the final step is requested", () => {
  vi.useFakeTimers();
  const { result, rerender, unmount } = renderHook(
    ({ step, visible }) => useDemoConversation(step, false, visible),
    { initialProps: { step: 0, visible: false } },
  );
  act(() => vi.advanceTimersByTime(4000));
  expect(result.current).toEqual([0, 0]);
  rerender({ step: 2, visible: true });
  act(() => vi.advanceTimersByTime(TURN_DURATION));
  expect(result.current).toEqual([TURN_DURATION, 0]);
  act(() => vi.advanceTimersByTime(TURN_DURATION));
  expect(result.current).toEqual([TURN_DURATION, TURN_DURATION]);
  expect(vi.getTimerCount()).toBe(0);
  rerender({ step: 0, visible: true });
  expect(result.current[0]).toBe(TURN_DURATION);
  unmount();
  expect(vi.getTimerCount()).toBe(0);
});
