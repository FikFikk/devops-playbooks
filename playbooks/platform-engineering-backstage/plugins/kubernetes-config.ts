// plugins/kubernetes-config.ts
// Konfigurasi Kubernetes Plugin untuk Backstage
// File ini menunjukkan cara integrasi plugin K8s ke backend dan frontend

// ─── BACKEND SETUP ────────────────────────────────────────────────────────────
// packages/backend/src/index.ts

import { KubernetesBuilder } from '@backstage/plugin-kubernetes-backend';
import { Router } from 'express';
import { PluginEnvironment } from '../types';

export default async function createPlugin(
  env: PluginEnvironment,
): Promise<Router> {
  const { router } = await KubernetesBuilder.createBuilder({
    logger: env.logger,
    config: env.config,
    discovery: env.discovery,
    permissions: env.permissions,
  }).build();
  return router;
}

// ─── FRONTEND SETUP ───────────────────────────────────────────────────────────
// packages/app/src/components/catalog/EntityPage.tsx

import React from 'react';
import {
  EntityLayout,
  EntityLinksCard,
  EntityAboutCard,
} from '@backstage/plugin-catalog';
import {
  EntityKubernetesContent,
  isKubernetesAvailable,
} from '@backstage/plugin-kubernetes';
import { EntityGithubActionsContent } from '@backstage/plugin-github-actions';
import {
  EntityArgoCDOverviewCard,
  isArgocdAvailable,
} from '@roadiehq/backstage-plugin-argo-cd';
import {
  EntityGrafanaDashboardsCard,
  EntityGrafanaAlertsCard,
} from '@k-phoen/backstage-plugin-grafana';
import {
  EntityPagerDutyCard,
  isPagerDutyAvailable,
} from '@pagerduty/backstage-plugin';

// ─── Entity Page Layout yang Comprehensive ────────────────────────────────────
export const serviceEntityPage = (
  <EntityLayout>
    {/* Tab: Overview — informasi dasar service */}
    <EntityLayout.Route path="/" title="Overview">
      <Grid container spacing={3}>
        <Grid item md={6}>
          <EntityAboutCard variant="gridItem" />
        </Grid>
        <Grid item md={6}>
          <EntityLinksCard />
        </Grid>
        
        {/* ArgoCD status card — tampil jika ada anotasi ArgoCD */}
        <EntityLayout.Route
          if={isArgocdAvailable}
          path="/"
        >
          <Grid item md={6}>
            <EntityArgoCDOverviewCard />
          </Grid>
        </EntityLayout.Route>
        
        {/* PagerDuty on-call status */}
        <EntityLayout.Route if={isPagerDutyAvailable}>
          <Grid item md={6}>
            <EntityPagerDutyCard />
          </Grid>
        </EntityLayout.Route>
      </Grid>
    </EntityLayout.Route>

    {/* Tab: CI/CD — GitHub Actions workflow */}
    <EntityLayout.Route path="/ci-cd" title="CI/CD">
      <EntityGithubActionsContent />
    </EntityLayout.Route>

    {/* Tab: Kubernetes — pod status real-time */}
    <EntityLayout.Route
      path="/kubernetes"
      title="Kubernetes"
      if={isKubernetesAvailable}
    >
      <EntityKubernetesContent refreshIntervalMs={30000} />
    </EntityLayout.Route>

    {/* Tab: Monitoring — Grafana dashboards dan alerts */}
    <EntityLayout.Route path="/monitoring" title="Monitoring">
      <Grid container spacing={3}>
        <Grid item md={12}>
          <EntityGrafanaDashboardsCard />
        </Grid>
        <Grid item md={12}>
          <EntityGrafanaAlertsCard />
        </Grid>
      </Grid>
    </EntityLayout.Route>

    {/* Tab: TechDocs — dokumentasi dari repo */}
    <EntityLayout.Route path="/docs" title="Docs">
      <EntityTechdocsContent />
    </EntityLayout.Route>
  </EntityLayout>
);

// ─── Plugin Registration di App.tsx ──────────────────────────────────────────
// packages/app/src/App.tsx

import { createApp } from '@backstage/app-defaults';
import { AppRouter, FlatRoutes } from '@backstage/core-app-api';

// Import plugin routes
import { KubernetesPage } from '@backstage/plugin-kubernetes';
import { githubActionsPlugin } from '@backstage/plugin-github-actions';
import { grafanaPlugin } from '@k-phoen/backstage-plugin-grafana';

const app = createApp({
  apis,
  // Daftarkan semua plugin yang digunakan
  plugins: [
    githubActionsPlugin,
    grafanaPlugin,
    // tambahkan plugin lain di sini
  ],
  components: {
    SignInPage: props => (
      <SignInPage
        {...props}
        auto
        providers={[
          'guest',           // Untuk local development
          {
            id: 'github-auth-provider',
            title: 'GitHub',
            message: 'Sign in menggunakan GitHub',
            apiRef: githubAuthApiRef,
          },
        ]}
      />
    ),
  },
});

export default app.createRoot(
  <AppRouter>
    <FlatRoutes>
      <Route path="/" element={<Navigate to="catalog" />} />
      <Route path="/catalog" element={<CatalogIndexPage />} />
      <Route
        path="/catalog/:namespace/:kind/:name"
        element={<CatalogEntityPage />}
      >
        {entityPage}
      </Route>
      <Route path="/create" element={<ScaffolderPage />} />
      <Route path="/docs" element={<TechDocsIndexPage />} />
      <Route
        path="/docs/:namespace/:kind/:name/*"
        element={<TechDocsReaderPage />}
      />
      <Route path="/api-docs" element={<ApiExplorerPage />} />
      <Route path="/kubernetes" element={<KubernetesPage />} />
      <Route path="/search" element={<SearchPage />} />
      <Route path="/settings" element={<UserSettingsPage />} />
    </FlatRoutes>
  </AppRouter>,
);

// ─── Konfigurasi API Refs untuk Plugin ───────────────────────────────────────
// packages/app/src/apis.ts

import {
  ScmIntegrationsApi,
  scmIntegrationsApiRef,
  ScmAuth,
  scmAuthApiRef,
} from '@backstage/integration-react';
import {
  graphQlBrowseApiRef,
  GraphQLEndpoints,
} from '@backstage/plugin-graphiql';

export const apis: AnyApiFactory[] = [
  createApiFactory({
    api: scmIntegrationsApiRef,
    deps: { configApi: configApiRef },
    factory: ({ configApi }) => ScmIntegrationsApi.fromConfig(configApi),
  }),
  ScmAuth.createDefaultApiFactory(),
  
  // Grafana API (contoh custom API factory)
  createApiFactory({
    api: grafanaApiRef,
    deps: { discoveryApi: discoveryApiRef, identityApi: identityApiRef },
    factory: ({ discoveryApi, identityApi }) =>
      new GrafanaApiClient({ discoveryApi, identityApi }),
  }),
];
