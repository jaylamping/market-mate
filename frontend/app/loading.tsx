export default function Loading() {
  return (
    <main className="overview-state" aria-busy="true" aria-label="Loading supervisory evidence">
      <div className="overview-state-panel">
        <strong>Loading supervisory evidence</strong>
        <div className="state-skeleton" aria-hidden="true"><span /><span /><span /></div>
      </div>
    </main>
  );
}
