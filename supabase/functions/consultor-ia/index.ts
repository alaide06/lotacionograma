import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Plan = {
  intent?: "list" | "count" | "summary" | "unknown";
  clarification?: string | null;
  groupBy?: "promotoria" | "tipo" | "situacao" | "titular" | "destinacao" | null;
  filters?: Record<string, unknown>;
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function keyForClient() {
  const map = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (map) {
    try {
      const parsed = JSON.parse(map);
      if (parsed.default) return parsed.default;
    } catch (_error) {
      // Compatibilidade com ambientes que ainda expõem a variável legada.
    }
  }
  return Deno.env.get("SUPABASE_ANON_KEY") || "";
}

function situacao(dataInicial: string | null, dataFinal: string | null) {
  const hoje = new Date();
  hoje.setHours(0, 0, 0, 0);
  if (!dataInicial) return "Indefinido";
  const inicial = new Date(`${dataInicial}T00:00:00`);
  const final = dataFinal ? new Date(`${dataFinal}T00:00:00`) : null;
  if (inicial > hoje) return "Futuro";
  if (final && final < hoje) return "Encerrado";
  return "Presente";
}

function normalizarBusca(value: unknown) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLocaleLowerCase("pt-BR")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

function textoCombina(valor: unknown, filtro: unknown) {
  const alvo = normalizarBusca(valor);
  const busca = normalizarBusca(filtro);
  if (!busca) return true;
  if (!alvo) return false;
  return alvo.includes(busca) || busca.includes(alvo);
}

function between(value: string | null, from: unknown, to: unknown) {
  if (!value) return false;
  const date = new Date(`${value}T00:00:00`).getTime();
  const start = from ? new Date(`${String(from)}T00:00:00`).getTime() : -Infinity;
  const end = to ? new Date(`${String(to)}T00:00:00`).getTime() : Infinity;
  return date >= start && date <= end;
}

function limparPlano(raw: Plan): Plan {
  const allowedIntents = ["list", "count", "summary", "unknown"];
  const allowedGroups = ["promotoria", "tipo", "situacao", "titular", "destinacao"];
  const filters = raw?.filters && typeof raw.filters === "object" ? raw.filters : {};
  const clean: Record<string, unknown> = {};
  for (const key of [
    "search", "promotoria", "titular", "substituto", "tipo", "destinacao",
    "situacao", "referencia", "resumo", "dataInicialFrom", "dataInicialTo", "missingField",
  ]) {
    if (typeof filters[key] === "string") clean[key] = filters[key].trim().slice(0, 200);
  }
  if (typeof filters.apenasAtivos === "boolean") clean.apenasAtivos = filters.apenasAtivos;
  return {
    intent: allowedIntents.includes(String(raw?.intent)) ? raw.intent : "unknown",
    clarification: typeof raw?.clarification === "string" ? raw.clarification.slice(0, 300) : null,
    groupBy: allowedGroups.includes(String(raw?.groupBy)) ? raw.groupBy : null,
    filters: clean,
  };
}

async function interpretarPergunta(question: string, promotorias: string[], tipos: string[]) {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) throw new Error("A secret GEMINI_API_KEY não está configurada.");
  const model = Deno.env.get("GEMINI_MODEL") || "gemini-3.6-flash";
  const hoje = new Date().toISOString().slice(0, 10);
  const prompt = `Você é o interpretador de consultas de um sistema de lotacionograma. Hoje é ${hoje}.
Converta a pergunta do usuário em um plano JSON. Não responda a pergunta e não invente dados.
Use somente estes campos:
{
  "intent": "list" | "count" | "summary" | "unknown",
  "clarification": string | null,
  "groupBy": "promotoria" | "tipo" | "situacao" | "titular" | "destinacao" | null,
  "filters": {
    "search": string,
    "promotoria": string,
    "titular": string,
    "substituto": string,
    "tipo": string,
    "destinacao": string,
    "situacao": "Presente" | "Futuro" | "Encerrado" | "Indefinido",
    "referencia": string,
    "resumo": string,
    "dataInicialFrom": "YYYY-MM-DD",
    "dataInicialTo": "YYYY-MM-DD",
    "apenasAtivos": boolean,
    "missingField": "titular" | "substituto" | "tipo" | "promotoria" | null
  }
}
Regras: omita filtros que não foram pedidos; para contagens por categoria use intent summary e groupBy; para “ativos” use apenasAtivos true; se não entender peça esclarecimento em clarification.
Promotorias disponíveis: ${JSON.stringify(promotorias.slice(0, 300))}
Tipos disponíveis: ${JSON.stringify(tipos)}
Pergunta do usuário: ${JSON.stringify(question)}`;

  const modelos = [...new Set([model, "gemini-3.5-flash", "gemini-3.1-flash-lite"])]
    .filter(Boolean);
  let ultimoErro: Error | null = null;

  for (const modelo of modelos) {
    try {
      const text = await chamarGemini(apiKey, modelo, prompt);
      const cleaned = text.replace(/^```json\s*/i, "").replace(/\s*```$/i, "").trim();
      return limparPlano(JSON.parse(cleaned));
    } catch (error) {
      ultimoErro = error instanceof Error ? error : new Error("Falha ao consultar o Gemini.");
      console.error(`Gemini error (${modelo})`, ultimoErro.message);
    }
  }

  throw ultimoErro || new Error("O Gemini não conseguiu interpretar a pergunta.");
}

function esperar(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function chamarGemini(apiKey: string, model: string, prompt: string) {
  const requestBody = {
    contents: [{ role: "user", parts: [{ text: prompt }] }],
    generationConfig: { temperature: 0, responseMimeType: "application/json" },
  };
  let lastMessage = "O Gemini não conseguiu interpretar a pergunta.";

  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(apiKey)}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(requestBody),
      },
    );
    const payload = await response.json();
    if (response.ok) {
      return payload?.candidates?.[0]?.content?.parts?.[0]?.text || "{}";
    }

    lastMessage = payload?.error?.message || lastMessage;
    const temporario = response.status === 408 || response.status === 429 || response.status >= 500;
    if (!temporario || attempt === 1) break;
    await esperar(800 * (attempt + 1));
  }

  throw new Error(lastMessage);
}

function aplicarFiltros(rows: any[], filters: Record<string, unknown>) {
  const textFilter = (row: any, field: string, value: unknown) =>
    !value || textoCombina(row[field], value);
  return rows.filter((row) => {
    const current = situacao(row.data_inicial, row.data_final);
    if (!textFilter(row, "promotoria", filters.promotoria)) return false;
    if (!textFilter(row, "titular", filters.titular)) return false;
    if (!textFilter(row, "substituto", filters.substituto)) return false;
    if (filters.tipo && !textoCombina(row.tipo, filters.tipo)) return false;
    if (!textFilter(row, "destinacao", filters.destinacao)) return false;
    if (filters.situacao && current !== filters.situacao) return false;
    if (!textFilter(row, "referencia", filters.referencia)) return false;
    if (filters.resumo && !textoCombina(`${row.resumo || ""} ${row.resumo_substituto || ""}`, filters.resumo)) return false;
    if (filters.search) {
      const searchable = [row.promotoria, row.titular, row.substituto, row.tipo, row.destinacao, row.referencia, row.resumo, row.resumo_substituto].join(" ");
      if (!textoCombina(searchable, filters.search)) return false;
    }
    if (filters.apenasAtivos && !["Presente", "Futuro"].includes(current)) return false;
    if (filters.missingField && row[String(filters.missingField)]) return false;
    if ((filters.dataInicialFrom || filters.dataInicialTo) && !between(row.data_inicial, filters.dataInicialFrom, filters.dataInicialTo)) return false;
    return true;
  }).map((row) => ({
    id: row.id,
    promotoria: row.promotoria || "",
    titular: row.titular || "",
    tipo: row.tipo || "",
    destinacao: row.destinacao || "",
    data_inicial: row.data_inicial || null,
    data_final: row.data_final || null,
    situacao: currentSituation(row),
    referencia: row.referencia || "",
    resumo: row.resumo || "",
    substituto: row.substituto || "",
  }));
}

function currentSituation(row: any) {
  return situacao(row.data_inicial, row.data_final);
}

function formatAnswer(plan: Plan, rows: any[]) {
  const filters = plan.filters || {};
  const prefix = plan.intent === "count" || plan.intent === "summary" ? `Foram encontrados ${rows.length} registro(s).` : `Encontrei ${rows.length} registro(s).`;
  if (!plan.groupBy || !rows.length) return prefix;
  const groups = new Map<string, number>();
  rows.forEach((row) => {
    const key = row[plan.groupBy as string] || "Não informado";
    groups.set(key, (groups.get(key) || 0) + 1);
  });
  const detail = [...groups.entries()].sort((a, b) => b[1] - a[1]).map(([key, count]) => `${key}: ${count}`).join("; ");
  return `${prefix} Distribuição por ${plan.groupBy}: ${detail}.`;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Método não permitido." }, 405);

  try {
    const body = await request.json();
    const question = String(body?.question || "").trim().slice(0, 1000);
    if (!question) return json({ error: "Informe uma pergunta." }, 400);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = keyForClient();
    if (!supabaseUrl || !supabaseKey) throw new Error("Configuração do Supabase indisponível.");
    const supabase = createClient(supabaseUrl, supabaseKey, { auth: { persistSession: false } });

    const [recordsResult, promotoriaResult] = await Promise.all([
      supabase.from("registros").select("id,promotoria,titular,tipo,destinacao,data_inicial,data_final,referencia,resumo,substituto,resumo_substituto"),
      supabase.from("promotorias").select("nome").order("nome"),
    ]);
    if (recordsResult.error) throw recordsResult.error;
    if (promotoriaResult.error) throw promotoriaResult.error;

    const rows = recordsResult.data || [];
    const promotorias = (promotoriaResult.data || []).map((row) => row.nome).filter(Boolean);
    const tipos = [...new Set(rows.map((row) => row.tipo).filter(Boolean))];
    const plan = await interpretarPergunta(question, promotorias, tipos);
    if (plan.intent === "unknown") return json({ ok: true, answer: plan.clarification || "Não consegui entender o filtro. Pode reformular a pergunta?", plan, total: 0, rows: [] });

    const filtered = aplicarFiltros(rows, plan.filters || {});
    const visibleRows = filtered.slice(0, 100);
    const answer = filtered.length === 0 && rows.length > 0
      ? `Nenhum registro correspondeu aos filtros. A consulta leu ${rows.length} registro(s) do banco, mas o filtro não encontrou correspondência.`
      : formatAnswer(plan, filtered);
    return json({
      ok: true,
      answer,
      plan,
      sourceTotal: rows.length,
      total: filtered.length,
      truncated: filtered.length > visibleRows.length,
      rows: visibleRows,
    });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Não foi possível consultar o sistema." }, 500);
  }
});
