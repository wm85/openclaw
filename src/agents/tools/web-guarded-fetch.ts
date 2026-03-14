import { ProxyAgent, fetch as undiciFetch } from "undici";
import {
  fetchWithSsrFGuard,
  type GuardedFetchOptions,
  type GuardedFetchResult,
  withStrictGuardedFetchMode,
  withTrustedEnvProxyGuardedFetchMode,
} from "../../infra/net/fetch-guard.js";
import type { SsrFPolicy } from "../../infra/net/ssrf.js";

const WEB_TOOLS_TRUSTED_NETWORK_SSRF_POLICY: SsrFPolicy = {
  dangerouslyAllowPrivateNetwork: true,
  allowRfc2544BenchmarkRange: true,
};

type WebToolGuardedFetchOptions = Omit<
  GuardedFetchOptions,
  "mode" | "proxy" | "dangerouslyAllowEnvProxyWithoutPinnedDns"
> & {
  timeoutSeconds?: number;
  useEnvProxy?: boolean;
  /** Explicit proxy URL; takes precedence over env-based proxy. */
  proxyUrl?: string;
};
type WebToolEndpointFetchOptions = Omit<WebToolGuardedFetchOptions, "policy" | "useEnvProxy">;

function resolveTimeoutMs(params: {
  timeoutMs?: number;
  timeoutSeconds?: number;
}): number | undefined {
  if (typeof params.timeoutMs === "number" && Number.isFinite(params.timeoutMs)) {
    return params.timeoutMs;
  }
  if (typeof params.timeoutSeconds === "number" && Number.isFinite(params.timeoutSeconds)) {
    return params.timeoutSeconds * 1000;
  }
  return undefined;
}

export async function fetchWithWebToolsNetworkGuard(
  params: WebToolGuardedFetchOptions,
): Promise<GuardedFetchResult> {
  const { timeoutSeconds, useEnvProxy, proxyUrl, ...rest } = params;
  const resolved = {
    ...rest,
    timeoutMs: resolveTimeoutMs({ timeoutMs: rest.timeoutMs, timeoutSeconds }),
  };

  // Explicit proxy URL: create a ProxyAgent-backed fetch, bypass env proxy logic.
  if (proxyUrl) {
    const agent = new ProxyAgent(proxyUrl);
    const proxyFetch = ((input: RequestInfo | URL, init?: RequestInit) =>
      undiciFetch(input as string | URL, {
        ...(init as Record<string, unknown>),
        dispatcher: agent,
      }) as unknown as Promise<Response>) as typeof fetch;
    return fetchWithSsrFGuard(
      withTrustedEnvProxyGuardedFetchMode({ ...resolved, fetchImpl: proxyFetch }),
    );
  }

  return fetchWithSsrFGuard(
    useEnvProxy
      ? withTrustedEnvProxyGuardedFetchMode(resolved)
      : withStrictGuardedFetchMode(resolved),
  );
}

async function withWebToolsNetworkGuard<T>(
  params: WebToolGuardedFetchOptions,
  run: (result: { response: Response; finalUrl: string }) => Promise<T>,
): Promise<T> {
  const { response, finalUrl, release } = await fetchWithWebToolsNetworkGuard(params);
  try {
    return await run({ response, finalUrl });
  } finally {
    await release();
  }
}

export async function withTrustedWebToolsEndpoint<T>(
  params: WebToolEndpointFetchOptions & { proxyUrl?: string },
  run: (result: { response: Response; finalUrl: string }) => Promise<T>,
): Promise<T> {
  return await withWebToolsNetworkGuard(
    {
      ...params,
      policy: WEB_TOOLS_TRUSTED_NETWORK_SSRF_POLICY,
      useEnvProxy: true,
    },
    run,
  );
}

export async function withStrictWebToolsEndpoint<T>(
  params: WebToolEndpointFetchOptions,
  run: (result: { response: Response; finalUrl: string }) => Promise<T>,
): Promise<T> {
  return await withWebToolsNetworkGuard(params, run);
}
