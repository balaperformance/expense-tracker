import { QueryClientProvider } from '@tanstack/react-query';
import { lazy, Suspense, type ComponentType, type ReactNode } from 'react';
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router';

import { AppShell } from '@/components/layout/AppShell';
import { DashboardPage } from '@/features/dashboard/DashboardPage';
import { LoginPage } from '@/features/auth/LoginPage';
import { AiChatProvider } from '@/state/aiChat';
import { AuthProvider, useAuth } from '@/state/auth';
import { FeedbackProvider } from '@/state/feedback';
import { queryClient } from '@/state/queryClient';
import { SessionBootstrap, SessionCleanup, Splash } from '@/state/session';
import { SettingsProvider } from '@/state/settings';

import { PushSync } from './PushSync';
import { UpdatePrompt } from './UpdatePrompt';

// Everything past the first screen is split out, so a cold start downloads
// only the shell, the dashboard and the sign-in screen.
const named = <K extends string>(load: () => Promise<Record<K, ComponentType>>, name: K) =>
  lazy(async () => ({ default: (await load())[name] }));

const RegisterPage = named(() => import('@/features/auth/RegisterPage'), 'RegisterPage');
const VerifyEmailPage = named(() => import('@/features/auth/VerifyEmailPage'), 'VerifyEmailPage');
const ExpensesPage = named(() => import('@/features/expenses/ExpensesPage'), 'ExpensesPage');
const ExpenseFormPage = named(() => import('@/features/expenses/ExpenseFormPage'), 'ExpenseFormPage');
const PasteSmsPage = named(() => import('@/features/sms/PasteSmsPage'), 'PasteSmsPage');
const IncomePage = named(() => import('@/features/income/IncomePage'), 'IncomePage');
const IncomeFormPage = named(() => import('@/features/income/IncomeFormPage'), 'IncomeFormPage');
const ReportsPage = named(() => import('@/features/reports/ReportsPage'), 'ReportsPage');
const SettingsPage = named(() => import('@/features/settings/SettingsPage'), 'SettingsPage');
const AccountsPage = named(() => import('@/features/accounts/AccountsPage'), 'AccountsPage');
const StatementPage = named(() => import('@/features/accounts/StatementPage'), 'StatementPage');
const ImportStatementPage = named(() => import('@/features/statementImport/ImportStatementPage'), 'ImportStatementPage');
const CreditCardsPage = named(() => import('@/features/creditCards/CreditCardsPage'), 'CreditCardsPage');
const CardStatementPage = named(() => import('@/features/creditCards/CardStatementPage'), 'CardStatementPage');
const ReceivablesPage = named(() => import('@/features/receivables/ReceivablesPage'), 'ReceivablesPage');
const BudgetsPage = named(() => import('@/features/budgets/BudgetsPage'), 'BudgetsPage');
const CategoriesPage = named(() => import('@/features/catalog/CategoriesPage'), 'CategoriesPage');
const PaymentMethodsPage = named(() => import('@/features/catalog/PaymentMethodsPage'), 'PaymentMethodsPage');
const AssistantPage = named(() => import('@/features/assistant/AssistantPage'), 'AssistantPage');
const ExportPage = named(() => import('@/features/export/ExportPage'), 'ExportPage');

function RequireAuth() {
  const { stage } = useAuth();
  const location = useLocation();
  if (stage === 'initialising') return <Splash />;
  if (stage === 'signedOut') return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  return (
    <SessionBootstrap>
      <AppShell />
      <PushSync />
    </SessionBootstrap>
  );
}

function PublicOnly({ children }: { children: ReactNode }) {
  const { stage } = useAuth();
  const location = useLocation();
  if (stage === 'initialising') return <Splash />;
  if (stage === 'signedIn') {
    const from = (location.state as { from?: string } | null)?.from;
    return <Navigate to={from && from !== '/login' ? from : '/'} replace />;
  }
  return children;
}

export function AppRoutes() {
  return (
    <Suspense fallback={<Splash />}>
      <Routes>
        <Route path="/login" element={<PublicOnly><LoginPage /></PublicOnly>} />
        <Route path="/register" element={<PublicOnly><RegisterPage /></PublicOnly>} />
        <Route path="/verify-email" element={<PublicOnly><VerifyEmailPage /></PublicOnly>} />
        <Route element={<RequireAuth />}>
          <Route index element={<DashboardPage />} />
          <Route path="expenses" element={<ExpensesPage />} />
          <Route path="expenses/new" element={<ExpenseFormPage />} />
          <Route path="expenses/sms" element={<PasteSmsPage />} />
          <Route path="expenses/:id" element={<ExpenseFormPage />} />
          <Route path="income" element={<IncomePage />} />
          <Route path="income/new" element={<IncomeFormPage />} />
          <Route path="income/:id" element={<IncomeFormPage />} />
          <Route path="reports" element={<ReportsPage />} />
          <Route path="settings" element={<SettingsPage />} />
          <Route path="accounts" element={<AccountsPage />} />
          <Route path="accounts/import" element={<ImportStatementPage />} />
          <Route path="accounts/:id" element={<StatementPage />} />
          <Route path="cards" element={<CreditCardsPage />} />
          <Route path="cards/:id" element={<CardStatementPage />} />
          <Route path="owed" element={<ReceivablesPage />} />
          <Route path="budgets" element={<BudgetsPage />} />
          <Route path="categories" element={<CategoriesPage />} />
          <Route path="payment-methods" element={<PaymentMethodsPage />} />
          <Route path="assistant" element={<AssistantPage />} />
          <Route path="export" element={<ExportPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Route>
      </Routes>
    </Suspense>
  );
}

export function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <SettingsProvider>
          <AiChatProvider>
            <FeedbackProvider>
              <BrowserRouter>
                <SessionCleanup />
                <AppRoutes />
              </BrowserRouter>
              <UpdatePrompt />
            </FeedbackProvider>
          </AiChatProvider>
        </SettingsProvider>
      </AuthProvider>
    </QueryClientProvider>
  );
}
