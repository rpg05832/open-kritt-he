import React from 'react';
import ReactDOM from 'react-dom/client';
import { RouterProvider } from 'react-router-dom';
import { router } from './router.jsx';
import { ThemeProvider, ChromeProvider } from './context/ui.jsx';
import './index.css';
import './hebrew.css';
import './security-theme.css';

if (import.meta.env.VITE_UI_LANGUAGE === 'he') {
  document.documentElement.lang = 'he';
  document.documentElement.dir = 'rtl';
  document.title = 'Open-Kritt — בדיקות אבטחה';
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <ThemeProvider>
      <ChromeProvider>
        <RouterProvider router={router} future={{ v7_startTransition: true }} />
      </ChromeProvider>
    </ThemeProvider>
  </React.StrictMode>
);
