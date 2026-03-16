"use client";

import Link from "next/link";
import { SettingsForm } from "@/components/settings/SettingsForm";
import { SpeakerManager } from "@/components/transcript/SpeakerManager";

export default function SettingsPage() {
  return (
    <main className="min-h-screen bg-neutral-950 text-white">
      <div className="mx-auto max-w-2xl px-6 py-8">
        <Link
          href="/"
          className="mb-4 inline-block text-sm text-neutral-500 hover:text-neutral-300"
        >
          &larr; Back to dashboard
        </Link>
        <h1 className="mb-8 text-2xl font-bold">Settings</h1>
        <SettingsForm />

        <hr className="my-8 border-neutral-800" />

        <h2 className="mb-4 text-lg font-semibold text-neutral-300">
          Speaker Profiles
        </h2>
        <p className="mb-4 text-xs text-neutral-500">
          Manage known speakers. Assign names to speakers in transcripts to save
          their voice profile for automatic identification in future meetings.
        </p>
        <SpeakerManager />
      </div>
    </main>
  );
}
