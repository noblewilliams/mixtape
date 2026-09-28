import { useEffect, type RefObject } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";

gsap.registerPlugin(ScrollTrigger);

export function usePageMotion(
  root: RefObject<HTMLDivElement | null>,
  enabled: boolean,
) {
  useEffect(() => {
    if (!enabled || !root.current) return;
    const media = gsap.matchMedia();
    const ctx = gsap.context(() => {
      gsap.from(".hero-copy > *", {
        y: 24,
        opacity: 0,
        stagger: 0.085,
        duration: 0.9,
        ease: "power3.out",
        clearProps: "all",
      });
      gsap.from(".hero-art", {
        clipPath: "inset(0 0 100% 0)",
        duration: 1.15,
        ease: "power3.inOut",
        clearProps: "clipPath",
      });
      media.add(
        "(min-width: 800px) and (prefers-reduced-motion: no-preference)",
        () => {
          gsap.fromTo(
            ".hero-photo",
            { yPercent: -4, scale: 1.09 },
            {
              yPercent: 9,
              scale: 1.03,
              ease: "none",
              scrollTrigger: {
                trigger: ".hero",
                start: "top top",
                end: "bottom top",
                scrub: 0.8,
              },
            },
          );
          gsap.fromTo(
            ".feature-tape",
            { y: 32, rotation: -13 },
            {
              y: -32,
              rotation: -5,
              ease: "none",
              scrollTrigger: {
                trigger: ".feature-grid",
                start: "top bottom",
                end: "bottom top",
                scrub: 1,
              },
            },
          );
          gsap.fromTo(
            ".sleeve-stack",
            { y: 36, rotation: 9 },
            {
              y: -25,
              rotation: -3,
              ease: "none",
              scrollTrigger: {
                trigger: ".feature-grid",
                start: "top bottom",
                end: "bottom top",
                scrub: 1,
              },
            },
          );
        },
        root,
      );
      gsap.fromTo(
        ".prism-band",
        { backgroundPosition: "0% 50%" },
        {
          backgroundPosition: "100% 50%",
          ease: "none",
          scrollTrigger: {
            trigger: ".prism-band",
            start: "top bottom",
            end: "bottom top",
            scrub: 1,
          },
        },
      );
      gsap.fromTo(
        ".closing-glow",
        { scale: 1.1, rotation: -10 },
        {
          scale: 1.6,
          rotation: 12,
          ease: "none",
          scrollTrigger: {
            trigger: ".closing",
            start: "top bottom",
            end: "bottom bottom",
            scrub: 1,
          },
        },
      );
    }, root);
    return () => {
      media.revert();
      ctx.revert();
    };
  }, [enabled, root]);
}
