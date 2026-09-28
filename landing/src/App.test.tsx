import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { App } from "./App";

describe("landing entry points", () => {
  it("honours reduced motion without visible motion controls", () => {
    const { container } = render(<App />);
    expect(container.querySelector(".landing")).toHaveClass("motion-paused");
    expect(container.querySelector(".demo-runway")).toHaveClass("demo-static");
    expect(
      screen.queryByRole("button", { name: /animations|Motion on/i }),
    ).not.toBeInTheDocument();
  });
  it("keeps browser entry available when the download URL is not configured", () => {
    render(<App downloadUrl="" />);
    fireEvent.click(
      screen.getAllByRole("button", { name: /Download the app/ })[0],
    );
    const dialog = screen.getByRole("dialog");
    expect(
      within(dialog).getByText(/download link isn’t available yet/),
    ).toBeVisible();
    expect(
      within(dialog).getByRole("link", { name: /Open in browser/ }),
    ).toHaveAttribute("href", "/app/");
    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });
  it("keeps the three demo steps accessible without motion", async () => {
    render(<App />);
    const cover = screen
      .getByText("Space Song")
      .closest("li")!
      .querySelector("img")!
      .getAttribute("src");
    fireEvent.click(screen.getByRole("button", { name: /02 Make it yours/ }));
    expect(await screen.findByText("Midnight City")).toBeVisible();
    expect(
      screen
        .getByText("Space Song")
        .closest("li")!
        .querySelector("img")!
        .getAttribute("src"),
    ).toBe(cover);
    fireEvent.click(screen.getByRole("button", { name: /03 Press play/ }));
    expect(
      await screen.findByRole("link", { name: "Play mix" }),
    ).toHaveAttribute("href", "/app/");
    expect(
      screen.getByRole("link", { name: "Create playlist" }),
    ).toHaveAttribute("href", "/app/");
    expect(
      screen.getByText(
        "I need a mix for a late drive home, a little dreamy and nostalgic.",
        { selector: ".sr-only" },
      ),
    ).toBeVisible();
    expect(
      screen.getByText("A little more upbeat.", { selector: ".sr-only" }),
    ).toBeVisible();
    expect(screen.queryByText("A little preview")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Reset demo" }),
    ).not.toBeInTheDocument();
  });
});
