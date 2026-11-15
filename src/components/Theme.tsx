import {createContext, useContext, useEffect, useState, type ReactNode} from 'react';
import {Moon, Sun} from 'lucide-react';
import {Button} from './ui/button';

type Theme = 'dark' | 'light';
const ThemeContext = createContext<{theme: Theme; toggle: () => void} | null>(null);

function savedTheme(): Theme {
  try { return localStorage.getItem('sl.theme') === 'light' ? 'light' : 'dark'; }
  catch { return 'dark'; }
}

// Apply before React paints, including the initial loading state.
document.documentElement.dataset.theme = savedTheme();

export function ThemeProvider({children}: {children: ReactNode}) {
  const [theme, setTheme] = useState<Theme>(savedTheme);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try { localStorage.setItem('sl.theme', theme); } catch { /* Preference remains in memory. */ }
  }, [theme]);
  return <ThemeContext.Provider value={{theme, toggle: () => setTheme(t => t === 'dark' ? 'light' : 'dark')}}>{children}</ThemeContext.Provider>;
}

export function ThemeToggle({className = ''}: {className?: string}) {
  const context = useContext(ThemeContext);
  if (!context) return null;
  const dark = context.theme === 'dark';
  return <Button type="button" variant="ghost" size="icon" className={'theme-toggle ' + className}
    aria-label={'Switch to ' + (dark ? 'light' : 'dark') + ' theme'}
    title={'Switch to ' + (dark ? 'light' : 'dark') + ' theme'} onClick={context.toggle}>
    {dark ? <Sun size={19}/> : <Moon size={19}/>}
  </Button>;
}
