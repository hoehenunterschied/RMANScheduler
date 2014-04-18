-- prevent accidently execution of this worksheet as a script in sQL Developer
exit;
--
-- grant these to the user who installs the package
--
grant create job, create external job, create credential, select_catalog_role to scott;

-- make sure the timezone fits your location
begin
  dbms_scheduler.set_scheduler_attribute('default_timezone','Europe/Berlin');
end;
/

--
-- execute the scheduler_backup.xxx routines as the user who installed the package
--

--
-- Instructions
--

-- after installing the pacakge, call setup to create the credentials
-- and other Scheduler objects.
-- For the optional parameters db_database_role and configure_rman
-- the defaults 'sysdba' and 'false' are assumed if they are not provided
begin
  scheduler_backup.setup(os_username=>'oracle',os_password=>'oracle',
                         db_username=>'sys',db_password=>'oracle',
                         db_database_role=>'sysdba',configure_rman=>false);
end;
/

-- after the setup routine has been called, daily and weekly backups are made
-- according to the schedule.
--
-- If the password for the OS or DB account have been changed, call
-- modify credentials and provide the changed password or account name
-- Any combination of os/db username and password can be provieded
-- as parameter
exec scheduler_backup.modify_credentials(os_password=>'oracle');

-- When changes to the package have been made, call setup without parameters
-- This deletes all objects the package has created except the credentials
exec scheduler_backup.setup;

-- If you meed to change the names of the Scheduler objects this package
-- creates, call drop_objects first. This deletes the Scheduler objects
-- with the old names, that have beem created by this package:
exec scheduler_backup.drop_objects;
-- and calling setup creates new scheduler objects with the new names
begin
  scheduler_backup.setup(os_username=>'oracle',os_password=>'oracle',
                         db_username=>'sys',db_password=>'oracle');
end;
/

-- After other changes, excluding changes to the names or objects
-- are made to the package, just call setup without parameters
exec scheduler_backup.setup;
-- this will recreate all objects, thus applying changes to schedule or
-- RMAN commands without touching the credentials

-- query status of scheduler objects scheduler_backup has created
select * from table(scheduler_backup.status);

-- disable both daily and weekly backup jobs
exec scheduler_backup.disable;

-- enable both daily and weekly backup jobs
exec scheduler_backup.enable;

-- execute backup jobs on demand
exec dbms_scheduler.run_job(job_name=>'BACKUP_JOB_DAILY',use_current_session=>false);
exec dbms_scheduler.run_job(job_name=>'BACKUP_JOB_WEEKLY',use_current_session=>false);
--exec dbms_scheduler.drop_group(group_name=>'DAILY_NOT_SATURDAY');

-- display output of last RMAN session
select output from gv$rman_output where session_recid=(select max(session_recid) from v$rman_status) order by recid;



-- intialize the package
-- after calling this, we have daily incremental backups and weekly full backups
-- the database role is 'sysdba' if not specified otherwise here
exec scheduler_backup.setup(os_username=>'oracle',os_password=>'oracle',db_username=>'sys',db_password=>'oracle',db_database_role=>'sysdba',configure_rman=>false);
exec scheduler_backup.setup(os_username=>'dkfjd',os_password=>'kdfdkjf',db_username=>'dfkjd',db_password=>'dfdj',db_database_role=>'dkfjdkfj',configure_rman=>false);
exec scheduler_backup.modify_credentials;
exec scheduler_backup.modify_credentials(os_username=>'oracle',os_password=>'oracle');
exec scheduler_backup.modify_credentials(os_username=>'oracle',os_password=>'oracle',db_username=>'sys',db_password=>'oracle');

begin
  scheduler_backup.drop_objects;
  scheduler_backup.modify_credentials(os_username=>'oracle',os_password=>'oracle',db_username=>'sys',db_password=>'oracle');
  scheduler_backup.setup;
end;
/

select * from table(scheduler_backup.status);
select * from all_objects where object_name like 'BACKUP_%';

-- drops all objects scheduler_backup.setup has created
exec scheduler_backup.drop_objects;
exec scheduler_backup.drop_objects(drop_credentials=>false);

exec dbms_scheduler.close_window(window_name=>'SATURDAY_WINDOW');
exec dbms_scheduler.open_window(window_name=>'SATURDAY_WINDOW',duration=>interval '20' minute);

-- call this if you changed the scheduler_backup package, but the credentials did not change
exec scheduler_backup.setup;
-- to enforce RMAN configuration
exec scheduler_backup.setup(configure_rman=>true);

-- query status of scheduler objects scheduler_backup has created
select * from table(scheduler_backup.status);

-- disable both daily and weekly backup jobs
exec scheduler_backup.disable;

-- enable both daily and weekly backup jobs
exec scheduler_backup.enable;

-- execute backup jobs on demand
exec dbms_scheduler.run_job(job_name=>'BACKUP_JOB_DAILY',use_current_session=>false);
exec dbms_scheduler.run_job(job_name=>'BACKUP_JOB_WEEKLY',use_current_session=>false);
--exec dbms_scheduler.drop_group(group_name=>'DAILY_NOT_SATURDAY');

-- display output of last RMAN session
select output from gv$rman_output where session_recid=(select max(session_recid) from v$rman_status) order by recid;

desc scheduler_backup;
select * from v$nls_parameters;

-- display jobs
select * from all_scheduler_jobs where job_name like 'BACKUP_%'/**/;
-- display credentials
select * from all_credentials where credential_name like 'BACKUP_%_CREDENTIAL';
-- display programs
select * from all_scheduler_programs where program_name like 'BACKUP_%'/**/;
-- display schedules
select * from all_scheduler_schedules;
-- show scheduler windows
select * from all_scheduler_windows;
-- show scheduler windows
select * from all_scheduler_groups where group_name like 'BACKUP_%';
-- show when jobs have been run
select * from all_scheduler_job_log where job_name like 'BACKUP_%' /*and owner='SYS'/**/ order by log_date desc;
-- show state and next execution for jobs
select job_name,owner,STATE,NEXT_RUN_DATE,all_scheduler_jobs.* from all_scheduler_jobs where job_name like 'BACKUP_%' /*and owner='SYS'/**/;
-- show details about job runs
select * from all_scheduler_job_run_details where job_name like 'BACKUP_%'/**/ order by log_date desc;

select SID, START_TIME,TOTALWORK, sofar, (sofar/totalwork) * 100 "% done",sysdate + TIME_REMAINING/3600/24 end_at from gv$session_longops where totalwork > sofar AND opname NOT LIKE '%aggregate%' AND opname like 'RMAN%';

--display jobs and their schedule, regardless if schedule specified by named schedule or part of job definition
select j.owner,j.job_name,j.state,'schedule' "schedule defined as",j.schedule_name,s.repeat_interval from all_scheduler_jobs j, all_scheduler_schedules s where j.schedule_name=s.schedule_name union all
select j.owner,j.job_name,j.state,'window' "schedule defined as",j.schedule_name,w.repeat_interval from all_scheduler_jobs j, all_scheduler_windows w where j.schedule_name=w.window_name union all
select owner,job_name,state,'inline' "schedule defined as",null,repeat_interval from all_scheduler_jobs where schedule_name is null;

select job_name,req_start_date,actual_start_date,a.* from all_scheduler_job_run_details a where actual_start_date - req_start_date > interval '48' day;
select * from ALL_SCHEDULER_WINDOWS;
select * from ALL_SCHEDULER_WINDOW_DETAILS;
exec dbms_scheduler.enable('BACKUP_JOB_WEEKLY');
exec dbms_scheduler.open_window(window_name=>'SATURDAY_WINDOW',duration=>interval '20' minute);
exec dbms_scheduler.close_window(window_name=>'SATURDAY_WINDOW');
exec dbms_scheduler.open_window(window_name=>'SUNDAY_WINDOW',duration=>interval '20' minute);
exec dbms_scheduler.close_window(window_name=>'SUNDAY_WINDOW');
select dump(sysdate,16),dump(sysdate,10),sysdate from dual;
select * from all_objects where object_name like upper('all_scheduler_%') and owner='SYS';
select * from all_scheduler_window_groups;
select * from all_scheduler_wingroup_members where window_group_name='MAINTENANCE_WINDOW_GROUP';
select * from all_scheduler_jobs where schedule_name='MAINTENANCE_WINDOW_GROUP';
select * from  all_scheduler_chain_steps;

select * from all_objects where object_name='BACKUP_JOB_CHAIN';
exec dbms_scheduler.drop_chain(chain_name => 'BACKUP_JOB_CHAIN', force => true);

SELECT */*PLSQL_OPTIMIZE_LEVEL, PLSQL_CODE_TYPE/**/ FROM ALL_PLSQL_OBJECT_SETTINGS WHERE NAME = 'SCHEDULER_BACKUP';
desc all_plsql_object_settings;
alter session set plsql_code_type=native;
alter session set plsql_optimize_level=3;

set serveroutput on;
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-----------
set linesize 500
set longchunksize 500
set pages 50000
set long 2000000
set heading off
set echo off
set termout off
set feedback off
spool '/home/oracle/scheduler_backup_generated.sql' replace
exec dbms_metadata.set_transform_param(transform_handle=>DBMS_METADATA.SESSION_TRANSFORM,name=>'SQLTERMINATOR',value=>true);

exec dbms_metadata.set_transform_param(transform_handle=>DBMS_METADATA.SESSION_TRANSFORM,name=>'SPECIFICATION',value=>true);
exec dbms_metadata.set_transform_param(transform_handle=>DBMS_METADATA.SESSION_TRANSFORM,name=>'BODY',value=>false);
select dbms_metadata.get_ddl(object_type=>'PACKAGE',name=>'SCHEDULER_BACKUP_TYPES') from dual;
select dbms_metadata.get_ddl(object_type=>'PACKAGE',name=>'SCHEDULER_BACKUP') from dual;

exec dbms_metadata.set_transform_param(transform_handle=>DBMS_METADATA.SESSION_TRANSFORM,name=>'SPECIFICATION',value=>false);
exec dbms_metadata.set_transform_param(transform_handle=>DBMS_METADATA.SESSION_TRANSFORM,name=>'BODY',value=>true);
select dbms_metadata.get_ddl(object_type=>'PACKAGE',name=>'SCHEDULER_BACKUP_TYPES') from dual;
select dbms_metadata.get_ddl(object_type=>'PACKAGE',name=>'SCHEDULER_BACKUP') from dual;
spool off
