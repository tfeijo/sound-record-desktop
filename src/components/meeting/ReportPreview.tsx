"use client";

import type { MeetingSummary } from "@/lib/types";

interface ReportPreviewProps {
  summary: MeetingSummary;
}

export function ReportPreview({ summary }: ReportPreviewProps) {
  return (
    <div className="space-y-6">
      {/* Summary */}
      {summary.summary && (
        <section>
          <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-400">
            Summary
          </h3>
          <p className="text-sm leading-relaxed text-neutral-300">
            {summary.summary}
          </p>
        </section>
      )}

      {/* Decisions */}
      {summary.decisions?.length > 0 && (
        <section>
          <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-400">
            Key Decisions
          </h3>
          <ul className="space-y-1">
            {summary.decisions.map((d, i) => (
              <li key={i} className="flex gap-2 text-sm text-neutral-300">
                <span className="mt-0.5 text-emerald-500">&#x2022;</span>
                <span>{d}</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* Action Items */}
      {summary.action_items?.length > 0 && (
        <section>
          <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-400">
            Action Items
          </h3>
          <ul className="space-y-1.5">
            {summary.action_items.map((item, i) => (
              <li key={i} className="flex items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  disabled
                  className="mt-1 h-3.5 w-3.5 rounded border-neutral-600 bg-neutral-800"
                />
                <span className="text-neutral-300">
                  {item.description}
                  {item.assignee && (
                    <span className="ml-1 text-blue-400">@{item.assignee}</span>
                  )}
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* Topics */}
      {summary.topics?.length > 0 && (
        <section>
          <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-400">
            Discussion Topics
          </h3>
          <div className="space-y-3">
            {summary.topics.map((topic, i) => (
              <div key={i}>
                <h4 className="text-sm font-medium text-neutral-200">
                  {topic.title}
                </h4>
                <p className="mt-0.5 text-sm text-neutral-400">
                  {topic.summary}
                </p>
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
