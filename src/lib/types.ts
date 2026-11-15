export type Row={id:string;created_at?:string;workspace_id?:string;[key:string]:unknown};
export type Area='admin'|'provider'|'account'|'driver'|'warehouse';
export type Config={url:string;key:string};
export type Field={key:string;label:string;type?:'text'|'password'|'email'|'number'|'datetime-local'|'date'|'textarea'|'select'|'checkbox'|'file';required?:boolean;options?:(string|{value:string;label:string})[];relation?:string;default?:string|number|boolean;min?:number};
export type Module={title:string;table:string;description:string;fields?:Field[];columns:string[];search:string;scope?:boolean;create?:boolean;edit?:boolean;metrics?:{label:string;field?:string;value?:string}[]};
