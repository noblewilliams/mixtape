type ChooseServiceDialogProps = {
  onChooseApple: () => void
  onChooseSpotify: () => void
}

export function ChooseServiceDialog({ onChooseApple, onChooseSpotify }: ChooseServiceDialogProps) {
  return (
    <div className="overlay" role="presentation">
      <section className="dialog service-dialog" role="dialog" aria-modal="true" aria-labelledby="service-title">
        <p className="quiet-kicker">Before your first tape</p>
        <h2 id="service-title">Which do you use?</h2>
        <p>Mixtape builds mixes from what you actually listen to. Tell it where that lives.</p>
        <div className="mini-grid mini-grid--pair">
          <button className="mini" type="button" onClick={onChooseApple}>
            <strong>Apple Music</strong>
            <small>Connect in the browser and sync your library and playlists now.</small>
          </button>
          <button className="mini" type="button" onClick={onChooseSpotify}>
            <strong>Spotify</strong>
            <small>Ask Spotify for your listening data. It arrives by email within days; Mixtape reads it on this device.</small>
          </button>
        </div>
        <p className="note">You can add the other later from Your music.</p>
      </section>
    </div>
  )
}
