-- Your SQL goes here
CREATE OR REPLACE FUNCTION notification_service.notify(label text, data json)
 RETURNS notification_service.notifications
 LANGUAGE plpgsql
AS $function$
        declare
            _user community_service.users;
            _notification_template notification_service.notification_templates;
            _notification_global_template notification_service.notification_global_templates;
            _notification notification_service.notifications;
        begin
            select * from community_service.users
                where id = ($2 -> 'relations' ->>'user_id')::uuid 
                into _user;
            if _user.id is null then
                raise 'user_id not found';
            end if;
            
            select nt.* from notification_service.notification_templates nt  
                where nt.platform_id = _user.platform_id
                    and nt.label = $1
                    into _notification_template;

            if _notification_template is null then
                select ngt.* from notification_service.notification_global_templates ngt
                    where ngt.label = $1
                    into _notification_global_template;

                if _notification_global_template is null then
                    return null;
                end if;
            end if;

            insert into notification_service.notifications
                (platform_id, user_id, notification_template_id, notification_global_template_id, deliver_at, data)
            values (_user.platform_id, _user.id, _notification_template.id, _notification_global_template.id, coalesce(($2->>'deliver_at')::timestamp, now()), ($2)::jsonb)
            returning * into _notification;

            if _notification.deliver_at <= now() and not (($2->>'supress_notify')::boolean) then
                perform pg_notify('dispatch_notifications_channel', json_build_object('id', _notification.id)::text);
            end if;

            return _notification;
        end;
    $function$;

CREATE OR REPLACE FUNCTION payment_service.transition_to(payment payment_service.catalog_payments, status payment_service.payment_status, reason json)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
        declare
        begin
            -- check if to state is same from state
            if $1.status = $2 then
                return false;
            end if;
            
            -- generate a new payment status transition
            insert into payment_service.payment_status_transitions (catalog_payment_id, from_status, to_status, data)
                values ($1.id, $1.status, $2, ($3)::jsonb);

            -- update the payment status
            update payment_service.catalog_payments
                set status = $2,
                    updated_at = now()
                where id = $1.id;
                
            -- deliver notifications after status changes to paid
            if not exists (
                select true from notification_service.notifications n
                    where n.user_id = $1.user_id
                        and (n.data -> 'relations' ->> 'catalog_payment_id')::uuid = $1.id
            ) and $2 = 'paid' then 
                perform notification_service.notify('paid_payment', json_build_object(
                    'relations', json_build_object(
                        'catalog_payment_id', $1.id,
                        'subscription_id', $1.subscription_id,
                        'project_id', $1.project_id,
                        'reward_id', $1.reward_id,
                        'user_id', $1.user_id
                    )
                ));
            end if;
            

            return true;
        end;
    $function$
;