"use client";

import Link from "next/link";
import { SettingsForm } from "@/components/settings/SettingsForm";

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
      </div>
    </main>
  );
}
