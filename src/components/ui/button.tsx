import * as React from 'react';
import {Slot} from '@radix-ui/react-slot';
import {cva,type VariantProps} from 'class-variance-authority';
import {clsx,type ClassValue} from 'clsx';
import {twMerge} from 'tailwind-merge';
export const cn=(...v:ClassValue[])=>twMerge(clsx(v));
const variants=cva('ui-button',{variants:{variant:{default:'primary',outline:'outline',destructive:'destructive',ghost:'ghost'},size:{default:'',sm:'sm',icon:'icon'}},defaultVariants:{variant:'default',size:'default'}});
type Props=React.ButtonHTMLAttributes<HTMLButtonElement>&VariantProps<typeof variants>&{asChild?:boolean};
export const Button=React.forwardRef<HTMLButtonElement,Props>(({className,variant,size,asChild=false,...props},ref)=>{const Comp=asChild?Slot:'button';return <Comp ref={ref} className={cn(variants({variant,size}),className)} {...props}/>});Button.displayName='Button';
