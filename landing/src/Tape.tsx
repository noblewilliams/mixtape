// Use the same transparent cassette asset as the app, without an icon tile.
export function Tape({ title }: { title: string }) {
  return (
    <div className="tape">
      <img src="/images/tape.svg" alt="" width="200" height="128" />
      <span className="tape-title">{title}</span>
    </div>
  );
}
