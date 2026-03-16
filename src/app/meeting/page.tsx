"use client";

import { useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { MeetingDetail } from "@/components/transcript/MeetingDetail";

function MeetingContent() {
  const searchParams = useSearchParams();
  const id = searchParams.get("id");

  if (!id) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-neutral-950 text-white">
        <p className="text-neutral-500">No meeting ID provided.</p>
      </main>
    );
  }

  return <MeetingDetail meetingId={id} />;
}

export default function MeetingPage() {
  return (
    <Suspense
      fallback={
        <main className="flex min-h-screen items-center justify-center bg-neutral-950 text-white">
          <p className="text-neutral-500">Loading...</p>
        </main>
      }
    >
      <MeetingContent />
    </Suspense>
  );
}
