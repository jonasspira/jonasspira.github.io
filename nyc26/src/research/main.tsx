import { StrictMode, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { hasToken } from '../api';
import PinGate from '../pin-gate';
import ResearchApp from '../research-app';
import '../globals.css';

function Research() {
  const [open, setOpen] = useState(hasToken());
  const [notice, setNotice] = useState('');
  if (!open) {
    return (
      <PinGate
        notice={notice}
        onOpen={() => {
          setNotice('');
          setOpen(true);
        }}
      />
    );
  }
  return (
    <ResearchApp
      onSignedOut={(message) => {
        setNotice(message);
        setOpen(false);
      }}
    />
  );
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Research />
  </StrictMode>,
);
