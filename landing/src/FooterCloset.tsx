import { useEffect, useRef, useState, type CSSProperties } from "react";
import "./footer-closet.css";

const titles = [
  "The long way home",
  "Sunday kind of love",
  "After hours",
  "One more at the table",
  "First light",
  "City lights",
  "A little soul",
  "No place to be",
  "Second wind",
  "Blue hour",
  "Stay a little longer",
  "On repeat",
  "Windows down",
  "Kitchen dancing",
  "Before the world wakes",
  "Almost Friday",
  "Soft landing",
  "Rain on the roof",
  "Good company",
  "One more mile",
  "Quiet confidence",
  "Golden afternoon",
  "Out of office",
  "The night is young",
  "Slow mornings",
  "Old favourites",
  "Something unexpected",
  "Walking nowhere",
  "A room of our own",
  "Last train home",
  "Under the streetlights",
  "Headphones on",
  "A fresh start",
  "Dinner runs late",
  "Letters never sent",
  "Take your time",
  "Where we left off",
  "Small celebrations",
  "Warm weather",
  "Midnight thoughts",
  "The scenic route",
  "Just one more song",
  "Hands in the air",
  "Coffee for two",
  "A change of pace",
  "Through the city",
  "Nothing on the calendar",
  "The good part",
  "A little momentum",
  "Somewhere familiar",
  "All the way up",
  "Night swimming",
  "Backseat daydreams",
  "Between the lines",
  "Summer in September",
  "Stay for breakfast",
  "Half past happy",
  "Make yourself at home",
  "Close to the coast",
  "Before the lights go out",
  "Dancing in socks",
  "Saturday errands",
  "Meet me outside",
  "Moonlit drive",
  "Unfinished stories",
  "A softer evening",
  "Wildflowers",
  "In good time",
  "Heavy rotation",
  "Found in the shuffle",
  "Open windows",
  "See you tomorrow",
];

export function FooterCloset() {
  const row = useRef<HTMLDivElement>(null);
  const [capacity, setCapacity] = useState(8);
  useEffect(() => {
    const element = row.current;
    if (!element) return;
    // App closet proportions: a 44px case and a 3px gap. No decoration reserve here.
    const measure = () =>
      setCapacity(Math.max(1, Math.ceil((element.clientWidth + 3) / 47)));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return (
    <div className="footer-closet" ref={row} aria-hidden="true">
      {Array.from({ length: capacity }, (_, index) => {
        const title = titles[index] ?? `Late discoveries · ${index + 1}`;
        const hue = (index * 137.508 + 215) % 360;
        const lightness = [68, 57, 37, 72, 46, 61, 42][index % 7];
        const color = `hsl(${hue} 23% ${lightness}%)`;
        const variant = (index * 7 + Math.floor(index / 5)) % 4;
        const dark = lightness < 53;
        return (
          <div
            key={index}
            className={`closet-tape closet-variant-${variant}`}
            style={
              {
                "--case": color,
                "--ink": dark ? "#fff" : "#17161a",
                "--cap":
                  index % 3 === 0
                    ? color
                    : ["#e3ad62", "#cec3a7", "#5d454d", "#d6c07c"][variant],
                "--cap-ink": (index % 3 === 0 ? dark : variant === 2)
                  ? "#fff"
                  : "#17161a",
                "--endcap": color,
                "--end-ink": dark ? "#fff" : "#17161a",
              } as CSSProperties
            }
          >
            <span className="closet-insert">
              <span className="closet-print-top">
                <b>
                  {["90", "CRX", "60", "120", "C46", "SA", "80"][index % 7]}
                </b>
                <small>
                  MIN
                  <br />
                  STEREO
                </small>
              </span>
              <span className="closet-name">{title}</span>
              <span className="closet-print-bottom">
                <b>{variant === 3 ? "HF" : "A"}</b>
                <small>
                  MIXTAPE
                  <br />
                  SIDE A
                </small>
              </span>
            </span>
            <span className="closet-reflection" />
          </div>
        );
      })}
    </div>
  );
}
