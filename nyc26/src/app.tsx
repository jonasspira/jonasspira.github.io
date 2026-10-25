import { useState } from 'react';
import { hasToken } from './api';
import PinGate from './pin-gate';
import TripHub from './trip-hub';

export default function App() {
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
    <TripHub
      onSignedOut={(message) => {
        setNotice(message);
        setOpen(false);
      }}
    />
  );
}
