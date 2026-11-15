begin;
create function public.sl_cancel_booking(booking uuid,reason text) returns void
language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare b public.sl_bookings;
begin
  if not logistics_private.password_ready() then raise exception 'Sign in and complete password setup first';end if;
  select * into b from public.sl_bookings where id=booking for update;
  if not found then raise exception 'Booking not found';end if;
  if not (logistics_private.platform_admin() or b.customer_id=auth.uid()) then raise exception 'Only the customer or platform administrator may cancel this booking';end if;
  if b.status not in('requested','assigned','quoted','accepted','declined') or exists(select 1 from public.sl_shipments where booking_id=b.id) then raise exception 'This booking cannot be cancelled after shipment creation or cancellation';end if;
  if length(trim(coalesce(reason,'')))<3 then raise exception 'A cancellation reason is required';end if;
  update public.sl_bookings set status='cancelled',reason=trim(reason),updated_at=now() where id=booking;
  if b.workspace_id is not null then
    insert into public.sl_notifications(workspace_id,message,visibility) values(b.workspace_id,'Booking cancelled: '||b.reference,'provider');
    insert into public.sl_notifications(workspace_id,message,user_id,visibility) values(b.workspace_id,'Booking cancelled: '||b.reference,b.customer_id,'customer');
  end if;
end;$$;
revoke all on function public.sl_cancel_booking(uuid,text) from public,anon;
grant execute on function public.sl_cancel_booking(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
