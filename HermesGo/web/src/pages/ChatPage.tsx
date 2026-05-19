import { useState, useRef, useEffect, useCallback } from "react";
import { Send, Loader2, AlertCircle, Sparkles, XCircle, MessageSquare } from "lucide-react";
import { api } from "@/lib/api";
import type { ChatResponse } from "@/lib/api";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";

interface Message {
  role: "user" | "assistant" | "error";
  content: string;
  timestamp: number;
}

const STORAGE_KEY = "hermes-web-chat";

function loadHistory(): { messages: Message[]; sessionId: string | null } {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) return JSON.parse(raw);
  } catch {}
  return { messages: [], sessionId: null };
}

function saveHistory(messages: Message[], sessionId: string | null) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ messages, sessionId }));
  } catch {}
}

export default function ChatPage() {
  const saved = loadHistory();
  const [messages, setMessages] = useState<Message[]>(saved.messages);
  const [sessionId, setSessionId] = useState<string | null>(saved.sessionId);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => { saveHistory(messages, sessionId); }, [messages, sessionId]);

  const scrollToBottom = useCallback(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, []);

  useEffect(() => { scrollToBottom(); }, [messages, scrollToBottom]);

  const sendMessage = useCallback(async () => {
    const trimmed = input.trim();
    if (!trimmed || loading) return;
    setInput("");
    setError(null);
    setMessages((prev) => [...prev, { role: "user", content: trimmed, timestamp: Date.now() }]);
    setLoading(true);
    try {
      const resp: ChatResponse = await api.chat({
        message: trimmed,
        session_id: sessionId ?? undefined,
        timeout_sec: 600,
      });
      if (resp.session_id) setSessionId(resp.session_id);
      setMessages((prev) => [...prev, {
        role: resp.ok ? "assistant" : "error",
        content: resp.response || "(no response)",
        timestamp: Date.now(),
      }]);
      if (!resp.ok) setError(`Agent exited with code ${resp.exit_code}`);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      setError(msg);
      setMessages((prev) => [...prev, { role: "error", content: msg, timestamp: Date.now() }]);
    } finally {
      setLoading(false);
    }
  }, [input, loading, sessionId]);

  const clearChat = () => {
    if (confirm("Clear chat history?")) {
      setMessages([]);
      setSessionId(null);
      setError(null);
      saveHistory([], null);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  };

  return (
    <div className="flex flex-col h-[calc(100vh-6rem)] max-w-3xl mx-auto">
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <Sparkles className="h-5 w-5 text-muted-foreground" />
          <h2 className="font-display text-sm tracking-[0.15em] uppercase text-foreground">
            Chat
          </h2>
          {sessionId && (
            <Badge variant="secondary" className="ml-2 text-[0.6rem]">
              session: {sessionId.slice(0, 8)}...
            </Badge>
          )}
        </div>
        <button
          onClick={clearChat}
          className="flex items-center gap-1 text-[0.7rem] text-muted-foreground hover:text-foreground transition-colors cursor-pointer"
        >
          <XCircle className="h-3.5 w-3.5" /> Clear
        </button>
      </div>

      <Card className="flex-1 overflow-y-auto mb-3 p-4 border-border bg-card/60">
        {messages.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-muted-foreground gap-2">
            <MessageSquare className="h-10 w-10 opacity-20" />
            <p className="text-xs tracking-[0.1em] uppercase font-display">Start a conversation</p>
            <p className="text-[0.65rem] opacity-60 max-w-xs text-center">
              Chat with Hermes directly in your browser. Messages are saved locally.
            </p>
          </div>
        ) : (
          <div className="space-y-4">
            {messages.map((msg, i) => (
              <div key={i} className={`flex ${msg.role === "user" ? "justify-end" : "justify-start"}`}>
                <div className={`max-w-[85%] rounded-lg px-4 py-2.5 text-sm ${
                  msg.role === "user"
                    ? "bg-primary/10 text-foreground border border-border"
                    : msg.role === "error"
                      ? "bg-destructive/10 text-destructive border border-destructive/30"
                      : "bg-muted/50 text-foreground border border-border"
                }`}>
                  <div className="whitespace-pre-wrap break-words font-mono text-[0.8rem] leading-relaxed">
                    {msg.content}
                  </div>
                  <div className="text-[0.6rem] text-muted-foreground mt-1 opacity-50">
                    {new Date(msg.timestamp).toLocaleTimeString()}
                  </div>
                </div>
              </div>
            ))}
            {loading && (
              <div className="flex justify-start">
                <div className="flex items-center gap-2 rounded-lg px-4 py-2.5 bg-muted/50 border border-border">
                  <Loader2 className="h-3.5 w-3.5 animate-spin text-muted-foreground" />
                  <span className="text-xs text-muted-foreground font-display tracking-[0.1em]">Thinking...</span>
                </div>
              </div>
            )}
            <div ref={bottomRef} />
          </div>
        )}
      </Card>

      {error && (
        <div className="flex items-center gap-2 mb-2 px-3 py-2 rounded border border-destructive/30 bg-destructive/5 text-destructive text-xs">
          <AlertCircle className="h-3.5 w-3.5 shrink-0" />
          <span className="flex-1">{error}</span>
          <button onClick={() => setError(null)} className="text-destructive/60 hover:text-destructive cursor-pointer">
            <XCircle className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      <div className="flex gap-2">
        <textarea
          ref={inputRef}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Type your message... (Enter to send, Shift+Enter for new line)"
          rows={2}
          className="flex-1 resize-none rounded-lg border border-border bg-card px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring font-mono"
          disabled={loading}
        />
        <button
          onClick={sendMessage}
          disabled={loading || !input.trim()}
          className="flex items-center justify-center shrink-0 w-12 h-12 rounded-lg border border-border bg-card hover:bg-muted transition-colors disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer"
        >
          {loading ? <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" /> : <Send className="h-4 w-4 text-muted-foreground" />}
        </button>
      </div>
    </div>
  );
}
