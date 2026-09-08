"use client";
import { Dialog } from "radix-ui";
import { X } from "lucide-react";
import { type ReactNode } from "react";
import { Button } from "./button";
import { cn } from "@/lib/utils";
export function Inspection({
  open,
  onClose,
  title,
  description,
  side = false,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  description: string;
  side?: boolean;
  children: ReactNode;
}) {
  return (
    <Dialog.Root
      open={open}
      onOpenChange={(value) => {
        if (!value) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/30" />
        <Dialog.Content
          data-model-sheet={side}
          className={cn(
            "fixed z-50 flex flex-col border bg-background text-foreground shadow-lg",
            side
              ? "inset-y-0 right-0 w-full sm:max-w-[700px]"
              : "left-1/2 top-1/2 max-h-[90dvh] w-[calc(100%_-_2rem)] max-w-3xl -translate-x-1/2 -translate-y-1/2 rounded-xl",
          )}
        >
          <header className="flex items-start justify-between gap-4 border-b p-5">
            <div>
              <Dialog.Title className="text-lg font-semibold">
                {title}
              </Dialog.Title>
              <Dialog.Description className="mt-1 text-sm text-muted-foreground">
                {description}
              </Dialog.Description>
            </div>
            <Dialog.Close asChild>
              <Button variant="ghost" size="icon" aria-label="Close inspection">
                <X />
              </Button>
            </Dialog.Close>
          </header>
          <div className="min-h-0 overflow-y-auto p-5">{children}</div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
