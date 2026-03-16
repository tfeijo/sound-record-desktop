export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center bg-gray-950 text-white">
      <h1 className="mb-12 text-4xl font-bold tracking-tight">MeetNotes</h1>
      <p className="mb-8 text-gray-400">Click to start recording your meeting</p>
      <button
        className="flex h-32 w-32 items-center justify-center rounded-full bg-red-600 shadow-lg shadow-red-600/30 transition-all hover:scale-105 hover:bg-red-500 hover:shadow-red-500/40 active:scale-95"
        aria-label="Record"
      >
        <div className="h-12 w-12 rounded-full bg-white" />
      </button>
      <p className="mt-8 text-sm text-gray-500">Ready</p>
    </main>
  );
}
