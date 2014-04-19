CREATE OR REPLACE PACKAGE SCHEDULER_BACKUP_TYPES authid current_user AS
  --
  -- Author: Ralf Lange, ORACLE Deutschland
  -- 20140418

  -- type to identify object types
  subtype object_type_t IS INTEGER;

  type object_list_t IS TABLE OF object_type_t INDEX BY user_scheduler_jobs.job_name%type;

  FUNCTION initialize_object_list RETURN object_list_t;

END scheduler_backup_types;
/

show errors


CREATE OR REPLACE PACKAGE SCHEDULER_BACKUP authid current_user as
-- Ralf Lange, ORACLE Deutschland
-- 20140418

  -- this flag switches between schedules defined by g_{daily|weekly}_repeat_interval
  -- and windows based scheduling
  --
  -- windows based schedule : Backups happen during the nightly and weekend maintenance window
  --
  --               schedule : Backups happen according to schedule defined in this package
  --
  -- after changing the value, recompile and call scheduler_backup.setup without arguments
  -- to leave the credentials untouched but to recreate the other scheduler objects
  g_use_scheduler_windows constant boolean := false;

  -- scheduler_backup.backup only runs the backup job after
  -- a check of instance and database state.
  -- this flag controls what happens after the check fails:
  -- true : backups are permanently disabled until someone calls scheduler_backup.enable
  -- false: only the backup scheduled to run at the time of check is skipped.
  g_disable_after_failed_check constant boolean := false;

  -- RMAN commands for daily backup
  g_daily_commands varchar2(400) :=
         'backup check logical incremental level 1 for recover of copy with tag ''daily incr'' database;'
      || 'recover copy of database with tag ''daily incr'' until time ''sysdate-3'';'
      || 'backup check logical as compressed backupset archivelog all not backed up delete all input;';

  -- RMAN commands for weekly backup
  -- NOTE: at weekly backup, the commands for daily backup are executed as well!
  --       See definition of g_weekly_backup_script below
  g_weekly_commands varchar2(400) :=
         'backup check logical as compressed backupset database tag ''full backup'';'
      || 'backup check logical as compressed backupset archivelog all not backed up delete all input;'
      || 'delete noprompt obsolete;';

  -- RMAN configuration commands
  -- NOTE: RMAN configuration is only done if one of the dbms_scheduler.setup
  --       routines is called with Parameter rman_configuration=>true
  g_rman_configuration_commands varchar2(400) :=
         'configure retention policy to recovery window of 30 days;'
      || 'configure backup optimization on;'
      || 'configure default device type to disk;'
      || 'configure controlfile autobackup on;'
      || 'configure device type disk parallelism 1 backup type to compressed backupset;'
      || 'configure compression algorithm ''HIGH'' as of release ''DEFAULT'' optimize for load true;';

  -- the repeat interval for daily and weekly backup
  -- NOTE: No daily backup on Saturday because weekly backups execute
  --       on Saturday and include the commands of daily backup
  g_daily_repeat_interval user_scheduler_jobs.repeat_interval%type :=
         'freq=daily;byday=MON,TUE,WED,THU,FRI,SUN;byhour=5;byminute=10';
  g_weekly_repeat_interval user_scheduler_jobs.repeat_interval%type :=
         'freq=daily;byday=SAT;byhour=5;byminute=10';

  --
  -- if a strategy of daily and weekly RMAN backups fits your needs, no changes should
  -- be necessary below this line.
  --

  -- create RMAN run{..} blocks from g_{daily,weekly}_commands above
  -- NOTE: the RMAN run{..} block for weekly backup also includes the commands from daily backup!
  g_daily_backup_script        user_scheduler_jobs.job_action%type :=
         'run { ' || g_daily_commands || ' }';
  g_weekly_backup_script       user_scheduler_jobs.job_action%type :=
         'run { ' || g_daily_commands || g_weekly_commands|| ' }';

  -- The one stop shop for changing the database object names we create
  -- it is a good idea to call scheduler_backup.drop objects before changing names here
  -- Always use the variables, not the actual object names
  --
  -- Caution: If scheduler objects are added or removed from the list below, make
  --          sure to update the function scheduler_backup_types.initialize_object_list
  --          accordingly
  --
  g_prefix constant varchar2(20) := 'BACKUP_';
  g_daily_worker_name      constant                  user_scheduler_jobs.job_name%type := g_prefix||'WORKER_DAILY';
  g_weekly_worker_name     constant                  user_scheduler_jobs.job_name%type := g_prefix||'WORKER_WEEKLY';
  g_rman_conf_job_name     constant                  user_scheduler_jobs.job_name%type := g_prefix||'RMAN_CONF_JOB';
  g_os_credential_name     constant           user_scheduler_jobs.credential_name%type := g_prefix||'OS_CREDENTIAL';
  g_db_credential_name     constant   user_scheduler_jobs.connect_credential_name%type := g_prefix||'DB_CREDENTIAL';
  g_daily_except_sat_name  constant all_scheduler_window_groups.window_group_name%type := g_prefix||'DAILY_NOT_SATURDAY';
  g_daily_job_name         constant                user_scheduler_jobs.job_action%type := g_prefix||'JOB_DAILY';
  g_weekly_job_name        constant                user_scheduler_jobs.job_action%type := g_prefix||'JOB_WEEKLY';
  g_execute_backup_prgm    constant          user_scheduler_programs.program_name%type := g_prefix||'CHECK_EXECUTE_PRGM';


  -- default for the database role RMAN uses for database connections
  g_database_role user_scheduler_credentials.database_role%type := 'sysdba';

  type stringset_t is table of varchar2(200);

  -- convenience function to return status of objects created by this package
  -- this is how the function is called from SQL*Plus:
  -- select * from table(scheduler_backup.status);
  function status return stringset_t pipelined;

  -- This routine recreates all database objects except the credentials
  --
  -- Changes to RMAN commands, schedule are made by changing the package specification
  -- and recompiling the PL/SQL package. That does not change the database objects this
  -- script has created. After recompilation, call this routine to leave the
  -- credentials untouched. All database objects except the credentials are re-created
  -- An error is thrown if the credentials do not exist or are not enabled
  procedure setup(configure_rman in boolean default false);

  -- The one stop shop for setting up automated backups
  -- call this after installing the scheduler_backup PL/SQL package to
  -- set everything up. When this has been called successfully, the database
  -- starts automated backups according to the specified schedule.
  -- It does not hurt to call this routine again. But the provided parameters which
  -- include passwords can be seen in cleartext in V$SQL. Therefore it is better
  -- to call setup(configure_rman boolean) above. That call will recreate all
  -- objects except the credentials
  procedure setup(os_username      in varchar2,
                  os_password      in varchar2,
                  db_username      in varchar2,
                  db_password      in varchar2,
                  db_database_role in varchar2 default g_database_role,
                  configure_rman   in boolean  default false);

  -- backup performs some checks of database status and instance to see
  -- if a backup should be made. The reason is to avoid creating backups
  -- after a problematic state has been reached (these newly created backups
  -- might obsolete older backups)
  -- WARNING: This routine might permanently disable backups by calling scheduler_backup.disable
  --          check the implementation
  procedure backup(job_to_start in varchar2);

  -- check for existence of credentials
  function credentials_exist return boolean;

  -- create credentials
  procedure create_credentials(os_username      in varchar2 default null,
                               os_password      in varchar2 default null,
                               db_username      in varchar2 default null,
                               db_password      in varchar2 default null,
                               db_database_role in varchar2 default g_database_role);

  -- modify or create credentials if they do not exist
  procedure modify_credentials(os_username      in varchar2 default null,
                               os_password      in varchar2 default null,
                               db_username      in varchar2 default null,
                               db_password      in varchar2 default null,
                               db_database_role in varchar2 default g_database_role);

  -- enable the backup jobs
  -- after calling setup, jobs are already enabled
  -- this is only needed to re-enable them if they have been disabled afterwards
  -- the routine recreates all scheduler objects except the credentials
  procedure enable;

  -- disable the backup jobs
  -- the routine does not only disable jobs, it deletes all scheduler objects
  -- the scheduler_backup package has created-except the credentials
  -- the reason for deletion is: scheduler_backup.disable is called for a reason.
  -- usually in a critical situation to ensure no backups are made that might
  -- obsolete (in RMAN redundancy or recovery window terms) older backups.
  -- By deletion we prevent jobs that have been created outside of this package
  -- but are using the scheduler objects of this package from working.
  procedure disable;

  -- drops objects this package has created
  procedure drop_objects;
  procedure drop_objects(drop_credentials in boolean);

  -- the drop_objects procedure of this package will delete all database objects
  -- created by this package. To keep track of the objects created, we fill a
  -- global associative array (g_object_list) with the names of the objects
  -- and their object_type. These are constants to code the object_type
  k_job        constant scheduler_backup_types.object_type_t := 1;
  k_program    constant scheduler_backup_types.object_type_t := 2;
  k_credential constant scheduler_backup_types.object_type_t := 4;
  k_group      constant scheduler_backup_types.object_type_t := 8;

  C_SKIP_BACKUP_ERR       constant number := -20031;
  C_DISABLE_BACKUP_ERR    constant number := -20032;
  C_WRONG_JOB_NAME_ERR    constant number := -20033;
  C_NOT_ENOUGH_PARAMS_ERR constant number := -20034;
  C_NO_CREDENTIALS_ERR    constant number := -20035;

end scheduler_backup;
/

show errors


CREATE OR REPLACE PACKAGE BODY SCHEDULER_BACKUP_TYPES AS
  --
  -- Author: Ralf Lange, ORACLE Deutschland
  -- 20140418

  -- names and values must fit the scheduler object names and types created
  -- by scheduler_backup.
  FUNCTION initialize_object_list RETURN object_list_t IS
    ret object_list_t;
  BEGIN
    ret(scheduler_backup.g_daily_worker_name)     := scheduler_backup.k_job;
    ret(scheduler_backup.g_weekly_worker_name)    := scheduler_backup.k_job;
    ret(scheduler_backup.g_rman_conf_job_name)    := scheduler_backup.k_job;
    ret(scheduler_backup.g_os_credential_name)    := scheduler_backup.k_credential;
    ret(scheduler_backup.g_db_credential_name)    := scheduler_backup.k_credential;
    ret(scheduler_backup.g_daily_except_sat_name) := scheduler_backup.k_group;
    ret(scheduler_backup.g_daily_job_name)        := scheduler_backup.k_job;
    ret(scheduler_backup.g_weekly_job_name)       := scheduler_backup.k_job;
    ret(scheduler_backup.g_execute_backup_prgm)   := scheduler_backup.k_program;
    RETURN ret;
  END initialize_object_list;

END scheduler_backup_types;
/

show errors


CREATE OR REPLACE PACKAGE BODY SCHEDULER_BACKUP as
-- Ralf Lange, ORACLE Deutschland
-- 20140418

  -- associative array to hold names and type of database objects this package creates
  -- this is used by the drop_objects procedure
  g_object_list constant scheduler_backup_types.object_list_t := scheduler_backup_types.initialize_object_list;

  -- subset of setup procedure. this leaves the credentials untouched
  -- call this, if schedule or backup script have been changed, but credentials did not
  procedure setup (configure_rman in boolean default false) is
  begin
    -- err if credentials do not exist
    if not credentials_exist then
      raise_application_error(C_NO_CREDENTIALS_ERR, $$PLSQL_UNIT || '.setup() called without arguments,'
                                                || ' but credentials do not exist or are not ENABLED');
    end if;

    -- delete scheduler objects, but leave credentials untouched
    drop_objects(drop_credentials=>false);

  $IF scheduler_backup.g_use_scheduler_windows $THEN
    -- create a window group that contains all the nightly maintenance
    -- windows execept the SATURDAY_WINDOW
    dbms_scheduler.create_group(group_name=>g_daily_except_sat_name,
                                group_type=>'WINDOW',
                                member=>'MONDAY_WINDOW,TUESDAY_WINDOW,WEDNESDAY_WINDOW,' ||
                                        'THURSDAY_WINDOW,FRIDAY_WINDOW,SUNDAY_WINDOW',
                                comments=>'every day except Saturday');
  $END

    -- create scheduler objects
    -- for each daily and weekly backups two jobs are created. One program
    -- is shared by daily and weekly backups.
    --
    -- the relationship between scheduler objects for daily backup (weekly backup
    -- is architected the same):
    --
    --      JOB                  PROGRAM                 JOB
    -- g_daily_job_name -> g_execute_backup_prgm -> g_daily_worker_name
    -- the meaning of '->' is: the right side is invoked by the left side
    --
    -- 1. scheduler starts g_daily_job_name
    -- 2. g_daily_job_name executes g_execute_backup_prgm and passes the worker job
    --                              to execute as argument. g_execute_backup_prgm checks
    --                              if conditions for executing backups are met.
    -- 3. If conditions are met, g_execute_backup_prgrm executes g_daily_worker_name
    -- 4. g_daily_worker_name performs RMAN backup

    -- only one program is called for daily and weekly backup
    -- the program receives the worker job as argument.
    dbms_scheduler.create_program(program_name=>g_execute_backup_prgm,
                                  program_type=>'STORED_PROCEDURE',
                                  program_action=>'scheduler_backup.backup',
                                  number_of_arguments=>1,
                                  enabled=>false);

    dbms_scheduler.define_program_argument(program_name=>g_execute_backup_prgm,
                                           argument_position=>1,
                                           argument_type=>'VARCHAR2',
                                           default_value=>g_daily_worker_name);
    dbms_scheduler.enable(name=>g_execute_backup_prgm);

    -- create jobs for DAILY execution
    dbms_scheduler.create_job(job_name => g_daily_worker_name,
                              job_type => 'BACKUP_SCRIPT',
                              job_action => g_daily_backup_script,
                              credential_name => g_os_credential_name,
                              enabled => false,
                              auto_drop => false,
                              comments => 'backup job (daily execution)');
    dbms_scheduler.set_attribute(name=>g_daily_worker_name,
                                 attribute=>'CONNECT_CREDENTIAL_NAME',
                                 value=>g_db_credential_name);

    dbms_scheduler.create_job(job_name=>g_daily_job_name,
                              program_name=>g_execute_backup_prgm,
                            $IF scheduler_backup.g_use_scheduler_windows $THEN
                              schedule_name => g_daily_except_sat_name,
                            $ELSE
                              start_date => sysdate,
                              repeat_interval => g_daily_repeat_interval,
                            $END
                              enabled=>false,
                              comments=>'execute backup job if conditions are met');

    dbms_scheduler.set_job_argument_value(job_name=>g_daily_job_name,
                                          argument_position=>1,
                                          argument_value=>g_daily_worker_name);
    dbms_scheduler.enable(name=>g_daily_job_name);

    -- create jobs for WEEKLY execution
    dbms_scheduler.create_job(job_name => g_weekly_worker_name,
                              job_type => 'BACKUP_SCRIPT',
                              job_action => g_weekly_backup_script,
                              credential_name => g_os_credential_name,
                              enabled => false,
                              auto_drop => false,
                              comments => 'backup job (weekly execution)');
    dbms_scheduler.set_attribute(name=>g_weekly_worker_name,
                                 attribute=>'CONNECT_CREDENTIAL_NAME',
                                 value=>g_db_credential_name);

    dbms_scheduler.create_job(job_name=>g_weekly_job_name,
                              program_name=>g_execute_backup_prgm,
                            $IF scheduler_backup.g_use_scheduler_windows $THEN
                              schedule_name => 'SATURDAY_WINDOW',
                            $ELSE
                              start_date => sysdate,
                              repeat_interval => g_weekly_repeat_interval,
                            $END
                              enabled=>false,
                              comments=>'execute backup job if conditions are met');
    dbms_scheduler.set_job_argument_value(job_name=>g_weekly_job_name,
                                          argument_position=>1,
                                          argument_value=>g_weekly_worker_name);
    dbms_scheduler.enable(name=>g_weekly_job_name);

    -- create RMAN configuration job if needed
    if not configure_rman then
      return;
    end if;
    -- configure rman
    dbms_scheduler.create_job(job_name => g_rman_conf_job_name,
                              job_type => 'BACKUP_SCRIPT',
                              job_action => g_rman_configuration_commands,
                              credential_name => g_os_credential_name,
                              enabled => false,
                              auto_drop => false,
                              comments => 'RMAN configuration job');

    dbms_scheduler.set_attribute(name=> g_rman_conf_job_name,
                                 attribute=>'CONNECT_CREDENTIAL_NAME',
                                 value=>g_db_credential_name);
    dbms_scheduler.run_job(g_rman_conf_job_name);
  end setup;

  -- This is the routine to call after the package has been installed. After
  -- successfull execution the database will be backed up according to schedule
  procedure setup(os_username      in varchar2,
                  os_password      in varchar2,
                  db_username      in varchar2,
                  db_password      in varchar2,
                  db_database_role in varchar2 default g_database_role,
                  configure_rman   in boolean default false) is
  begin

    -- if the scheduler objects exist, they are deleted before creating them again
    drop_objects(drop_credentials=>true);

    -- create OS and DB credentials
    create_credentials(os_username=>os_username, os_password=>os_password,
                       db_username=>db_username, db_password=>db_password,
                       db_database_role=>db_database_role);

    -- create programs and jobs
    setup(configure_rman=>configure_rman);

  end setup;

  -- procedure backup is called by daily and weekly backup and receives the name of the
  -- worker job (the one which actually does the RMAN backup) to execute as argument.
  -- some checks are performed to decide if database and instance are in the right state
  -- for backup
  procedure backup (job_to_start in varchar2) is
    rows integer;
  begin
    -- the job we call must exist and be one of the two worker jobs.
    select count(*) into rows from user_scheduler_jobs where job_name in (g_daily_worker_name,g_weekly_worker_name)
                                                             and job_name=job_to_start;
    if SQL%NOTFOUND then
      raise_application_error(C_WRONG_JOB_NAME_ERR,    $$PLSQL_UNIT || '.backup: '
             || 'Job ''' || job_to_start || ''' does not exist '
             || 'or is not one of '||g_daily_worker_name||','||g_weekly_worker_name);
    end if;
    --dbms_output.put_line('job_name : '||job_to_start||' rows : '||rows);
    -- only make backups if instance and database meet certain conditions
    select count(*) into rows
    from v$instance i, v$database d
    where i.status!='OPEN' or i.logins!='ALLOWED' or i.shutdown_pending!='NO'
      or i.database_status!='ACTIVE' or i.active_state!='NORMAL' or d.log_mode!='ARCHIVELOG';
    if rows!=0 then
      -- status check failed
      $IF scheduler_backup.g_disable_after_failed_check $THEN
        -- permanently disable backups until someone calls scheduler_backup.enable
        scheduler_backup.disable;
        raise_application_error(C_DISABLE_BACKUP_ERR, $$PLSQL_UNIT || '.backup: '
               || 'BACKUPS DISABLED DUE TO INSTANCE/DATABASE STATUS');
      $ELSE
        raise_application_error(C_SKIP_BACKUP_ERR, $$PLSQL_UNIT || '.backup: '
               || 'BACKUP SKIPPED DUE TO INSTANCE/DATABASE STATUS');
      $END
    end if;
    dbms_scheduler.run_job(job_name=>job_to_start);
  end backup;

  -- guess what this does
  function credentials_exist return boolean is
    rows integer;
  begin
    select count(*) into rows
    from user_credentials
    where
        credential_name in (g_os_credential_name, g_db_credential_name)
      and
        enabled='TRUE';
    if rows != 2 then
        return false;
    end if;
    return true;
  end;

  procedure modify_credentials(os_username      in varchar2 default null,
                               os_password      in varchar2 default null,
                               db_username      in varchar2 default null,
                               db_password      in varchar2 default null,
                               db_database_role in varchar2  default g_database_role) is
  begin
    if    not credentials_exist
      and (   os_username is null or os_password is null
           or db_username is null or db_password is null) then
      -- credentials do not exist and one of the required parameters is null
      raise_application_error(C_NOT_ENOUGH_PARAMS_ERR,    $$PLSQL_UNIT || '.modify_credentials: '
             || 'Credentials do not exist and not enough parameters have been '
             || 'provided to create new ones');
    end if;
    if not credentials_exist then
      -- credentials do not exist but we have enough information to create new ones.
      create_credentials(os_username, os_password, db_username, db_password, db_database_role);
      return;
    end if;
    if     os_username is null and os_password is null
       and db_username is null and db_password is null then
      raise_application_error(C_NOT_ENOUGH_PARAMS_ERR,    $$PLSQL_UNIT || '.modify_credentials: '
             || 'Credentials do exist but no parameters were provided ');
    end if;
    -- from here on it's modification, not creation
    if os_username is not null then
      dbms_credential.update_credential(credential_name=>g_os_credential_name,
                                        attribute=>'USERNAME',
                                        value=>os_username);
    end if;
    if os_password is not null then
      dbms_credential.update_credential(credential_name=>g_os_credential_name,
                                        attribute=>'PASSWORD',
                                        value=>os_password);
    end if;
    if db_username is not null then
      dbms_credential.update_credential(credential_name=>g_db_credential_name,
                                        attribute=>'USERNAME',
                                        value=>db_username);
    end if;
    if db_password is not null then
      dbms_credential.update_credential(credential_name=>g_db_credential_name,
                                        attribute=>'PASSWORD',
                                        value=>db_password);
    end if;
    if db_database_role is not null then
      dbms_credential.update_credential(credential_name=>g_db_credential_name,
                                        attribute=>'DATABASE_ROLE',
                                        value=>db_database_role);
    end if;
  end modify_credentials;

  procedure create_credentials(os_username      in varchar2,
                               os_password      in varchar2,
                               db_username      in varchar2,
                               db_password      in varchar2,
                               db_database_role in varchar2 default g_database_role) is
    begin
      dbms_credential.create_credential(credential_name => g_os_credential_name,
                                        username => os_username,
                                        password => os_password,
                                        enabled => true,
                                        comments => 'OS credentials for backup jobs');

      dbms_credential.create_credential(credential_name => g_db_credential_name,
                                        username => db_username,
                                        password => db_password,
                                        database_role => g_database_role,
                                        enabled => true,
                                        comments => 'DB credentials for backup jobs');

    end create_credentials;

  procedure disable is
  begin
    -- just disabling the jobs would be the lightweight version
    -- of this implementation
    --dbms_scheduler.disable(name=>g_weekly_job_name);
    --dbms_scheduler.disable(name=>g_daily_job_name);
    drop_objects(drop_credentials=>false);
  end disable;

  procedure enable is
  begin
    --dbms_scheduler.enable(name=>g_weekly_job_name);
    --dbms_scheduler.enable(name=>g_daily_job_name);
    setup;
  end enable;

  -- display status of the objects we created
  function status return stringset_t pipelined is
    type job_list_t        is table of        user_scheduler_jobs%rowtype index by binary_integer;
    type prgm_list_t       is table of    user_scheduler_programs%rowtype index by binary_integer;
    type credential_list_t is table of user_scheduler_credentials%rowtype index by binary_integer;
    type group_list_t      is table of       all_scheduler_groups%rowtype index by binary_integer;
    job_list          job_list_t;
    prgm_list        prgm_list_t;
    cred_list  credential_list_t;
    group_list      group_list_t;
    l_row            pls_integer;
  begin
    select * bulk collect into job_list from user_scheduler_jobs where job_name like g_prefix||'%';
    l_row := job_list.first;
    while (l_row is not null)
    loop
      pipe row('       job : '||job_list(l_row).job_name||', enabled: '||job_list(l_row).enabled);
      l_row := job_list.next(l_row);
    end loop;
    select * bulk collect into prgm_list from user_scheduler_programs where program_name like g_prefix||'%';
    l_row := prgm_list.first;
    while (l_row is not null)
    loop
      pipe row('   program : '||prgm_list(l_row).program_name||', enabled: '||prgm_list(l_row).enabled);
      l_row := prgm_list.next(l_row);
    end loop;
    select * bulk collect into group_list from all_scheduler_groups where group_name like g_prefix||'%';
    l_row := group_list.first;
    while (l_row is not null)
    loop
      pipe row('     group : '||group_list(l_row).group_name||', enabled: '||group_list(l_row).enabled);
      l_row := group_list.next(l_row);
    end loop;
    select * bulk collect into cred_list from user_scheduler_credentials where credential_name like g_prefix||'%';
    l_row := cred_list.first;
    while (l_row is not null)
    loop
      pipe row('credential : '||cred_list(l_row).credential_name);
      l_row := cred_list.next(l_row);
    end loop;
    return;
  end status;


  -- if drop_objects is called without arguments, all objects are deleted
  procedure drop_objects is
  begin
    drop_objects(drop_credentials=>true);
  end drop_objects;

  procedure drop_objects(drop_credentials in boolean) is
  rows integer;
  object_name user_scheduler_jobs.job_name%type;
  begin

    object_name := g_object_list.first;
    while object_name is not null
    loop
      case g_object_list(object_name)
        when k_job then
          select count(*) into rows from user_scheduler_jobs where job_name=object_name;
          if rows > 0 then
            dbms_scheduler.drop_job(job_name=>object_name, force=>true);
            dbms_output.put_line($$PLSQL_UNIT||'.drop_objects: deleted '||object_name||' of type JOB');
          end if;

        when k_program then
          select count(*) into rows from user_scheduler_programs where program_name=object_name;
          if rows > 0 then
            dbms_scheduler.drop_program(program_name=>object_name, force=>true);
            dbms_output.put_line($$PLSQL_UNIT||'.drop_objects: deleted '||object_name||' of type PROGRAM');
          end if;

        when k_group then
          select count(*) into rows from user_scheduler_groups where group_name=object_name;
          if rows > 0 then
            dbms_scheduler.drop_group(group_name=>object_name, force=>true);
            dbms_output.put_line($$PLSQL_UNIT||'.drop_objects: deleted '||object_name||' of type GROUP');
          end if;

        when k_credential then
          select count(*) into rows from user_credentials where credential_name=object_name;
          if rows > 0 and drop_credentials then
            dbms_credential.drop_credential(credential_name => object_name, force => true);
            dbms_output.put_line($$PLSQL_UNIT||'.drop_objects: deleted '||object_name||' of type CREDENTIAL');
          end if;
      end case;

      object_name := g_object_list.next(object_name);
    end loop;

  end drop_objects;

end scheduler_backup;
/

show errors
