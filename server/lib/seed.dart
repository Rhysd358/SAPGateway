import 'schema.dart';

Property _str(String name,
        {int? maxLength, bool key = false, bool nullable = true, String? label}) =>
    Property(
      name: name,
      type: 'string',
      maxLength: maxLength,
      key: key,
      nullable: nullable,
      label: label,
    );

Property _dt(String name,
        {bool key = false, bool nullable = true, String? label}) =>
    Property(
      name: name,
      type: 'datetime',
      key: key,
      nullable: nullable,
      label: label,
    );

Property _dec(String name,
        {int precision = 13, int scale = 2, bool nullable = true, String? label}) =>
    Property(
      name: name,
      type: 'decimal',
      precision: precision,
      scale: scale,
      nullable: nullable,
      label: label,
    );

Property _int(String name,
        {bool key = false, bool nullable = true, String? label}) =>
    Property(
      name: name,
      type: 'int',
      key: key,
      nullable: nullable,
      label: label,
    );

GatewayState buildSeed() {
  final employeeType = EntityType(
    name: 'Employee',
    properties: [
      _str('PERNR', maxLength: 8, key: true, nullable: false, label: 'Personnel number'),
      _str('NACHN', maxLength: 40, label: 'Last name'),
      _str('VORNA', maxLength: 40, label: 'First name'),
      _dt('GBDAT', label: 'Date of birth'),
      _dt('BEGDA', label: 'Start date'),
      _dt('ENDDA', label: 'End date'),
      _str('WERKS', maxLength: 4, label: 'Personnel area'),
      _str('PERSG', maxLength: 1, label: 'Employee group'),
      _str('PERSK', maxLength: 2, label: 'Employee subgroup'),
    ],
  );

  final addressType = EntityType(
    name: 'Address',
    properties: [
      _str('PERNR', maxLength: 8, key: true, nullable: false, label: 'Personnel number'),
      _str('SUBTY', maxLength: 4, key: true, nullable: false, label: 'Address subtype'),
      _str('STRAS', maxLength: 60, label: 'Street'),
      _str('ORT01', maxLength: 40, label: 'City'),
      _str('PSTLZ', maxLength: 10, label: 'Postcode'),
      _str('LAND1', maxLength: 3, label: 'Country code'),
    ],
  );

  final orgUnitType = EntityType(
    name: 'OrgUnit',
    properties: [
      _str('ORGEH', maxLength: 8, key: true, nullable: false, label: 'Organizational unit'),
      _str('ORGTX', maxLength: 40, label: 'Org unit text'),
      _str('PLVAR', maxLength: 2, label: 'Plan version'),
      _dt('BEGDA', label: 'Start date'),
      _dt('ENDDA', label: 'End date'),
    ],
  );

  final positionType = EntityType(
    name: 'Position',
    properties: [
      _str('PLANS', maxLength: 8, key: true, nullable: false, label: 'Position'),
      _str('PLSTX', maxLength: 40, label: 'Position text'),
      _str('ORGEH', maxLength: 8, label: 'Organizational unit'),
      _str('STELL', maxLength: 8, label: 'Job'),
      _dt('BEGDA', label: 'Start date'),
      _dt('ENDDA', label: 'End date'),
    ],
  );

  final jobType = EntityType(
    name: 'Job',
    properties: [
      _str('STELL', maxLength: 8, key: true, nullable: false, label: 'Job'),
      _str('STLTX', maxLength: 40, label: 'Job text'),
      _dt('BEGDA', label: 'Start date'),
      _dt('ENDDA', label: 'End date'),
    ],
  );

  final absenceType = EntityType(
    name: 'Absence',
    properties: [
      _str('PERNR', maxLength: 8, key: true, nullable: false, label: 'Personnel number'),
      _str('AWART', maxLength: 4, key: true, nullable: false, label: 'Absence type'),
      _dt('BEGDA', key: true, nullable: false, label: 'Start date'),
      _dt('ENDDA', label: 'End date'),
      _dec('ABWTG', precision: 5, scale: 1, label: 'Absence days'),
    ],
  );

  final timesheetType = EntityType(
    name: 'Timesheet',
    properties: [
      _str('PERNR', maxLength: 8, key: true, nullable: false, label: 'Personnel number'),
      _dt('WORKD', key: true, nullable: false, label: 'Work date'),
      _str('LSTAR', maxLength: 6, key: true, nullable: false, label: 'Activity type'),
      _dec('STDAZ', precision: 5, scale: 2, label: 'Hours'),
      _str('KOSTL', maxLength: 10, label: 'Cost centre'),
    ],
  );

  final payrollType = EntityType(
    name: 'PayrollResult',
    properties: [
      _str('PERNR', maxLength: 8, key: true, nullable: false, label: 'Personnel number'),
      _int('SEQNR', key: true, nullable: false, label: 'Sequence number'),
      _str('FPPER', maxLength: 6, label: 'Payroll period'),
      _str('PAYTY', maxLength: 1, label: 'Payroll type'),
      _dec('BETRG', label: 'Amount'),
      _str('WAERS', maxLength: 3, label: 'Currency'),
    ],
  );

  final wageTypeType = EntityType(
    name: 'WageType',
    properties: [
      _str('LGART', maxLength: 4, key: true, nullable: false, label: 'Wage type'),
      _str('LGTXT', maxLength: 40, label: 'Wage type text'),
    ],
  );

  final expenseType = EntityType(
    name: 'Expense',
    properties: [
      _str('BELNR', maxLength: 10, key: true, nullable: false, label: 'Document number'),
      _str('PERNR', maxLength: 8, nullable: false, label: 'Personnel number'),
      _dt('BLDAT', label: 'Document date'),
      _dec('WRBTR', label: 'Amount'),
      _str('WAERS', maxLength: 3, label: 'Currency'),
      _str('KOSTL', maxLength: 10, label: 'Cost centre'),
      _str('SAKNR', maxLength: 10, label: 'G/L account'),
      _str('SGTXT', maxLength: 50, label: 'Description'),
      _str('Status', maxLength: 12, label: 'Status'),
    ],
  );

  final employees = EntitySet(name: 'EmployeeSet', entityType: 'Employee', rows: [
    {
      'PERNR': '00001000',
      'NACHN': 'Jenkins',
      'VORNA': 'Marie',
      'GBDAT': '1982-04-11T00:00:00',
      'BEGDA': '2014-09-01T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
      'WERKS': '1000',
      'PERSG': '1',
      'PERSK': 'S0',
    },
    {
      'PERNR': '00001001',
      'NACHN': 'Okafor',
      'VORNA': 'Daniel',
      'GBDAT': '1990-07-23T00:00:00',
      'BEGDA': '2018-03-15T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
      'WERKS': '1000',
      'PERSG': '1',
      'PERSK': 'S1',
    },
    {
      'PERNR': '00001002',
      'NACHN': 'Andersson',
      'VORNA': 'Linnea',
      'GBDAT': '1975-12-02T00:00:00',
      'BEGDA': '2009-01-12T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
      'WERKS': '2000',
      'PERSG': '1',
      'PERSK': 'M2',
    },
  ]);

  final addresses = EntitySet(name: 'AddressSet', entityType: 'Address', rows: [
    {
      'PERNR': '00001000',
      'SUBTY': '1',
      'STRAS': '12 Heath Lane',
      'ORT01': 'Bristol',
      'PSTLZ': 'BS1 5TR',
      'LAND1': 'GB',
    },
    {
      'PERNR': '00001001',
      'SUBTY': '1',
      'STRAS': '88 Riverside Drive',
      'ORT01': 'Manchester',
      'PSTLZ': 'M14 4QQ',
      'LAND1': 'GB',
    },
    {
      'PERNR': '00001002',
      'SUBTY': '1',
      'STRAS': 'Storgatan 4',
      'ORT01': 'Stockholm',
      'PSTLZ': '11122',
      'LAND1': 'SE',
    },
  ]);

  final orgUnits = EntitySet(name: 'OrgUnitSet', entityType: 'OrgUnit', rows: [
    {
      'ORGEH': '50000010',
      'ORGTX': 'Finance UK',
      'PLVAR': '01',
      'BEGDA': '2010-01-01T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
    {
      'ORGEH': '50000020',
      'ORGTX': 'Engineering',
      'PLVAR': '01',
      'BEGDA': '2010-01-01T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
    {
      'ORGEH': '50000030',
      'ORGTX': 'People Operations',
      'PLVAR': '01',
      'BEGDA': '2012-04-01T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
  ]);

  final positions = EntitySet(name: 'PositionSet', entityType: 'Position', rows: [
    {
      'PLANS': '60000100',
      'PLSTX': 'Finance Analyst',
      'ORGEH': '50000010',
      'STELL': '70000010',
      'BEGDA': '2014-09-01T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
    {
      'PLANS': '60000200',
      'PLSTX': 'Senior Engineer',
      'ORGEH': '50000020',
      'STELL': '70000020',
      'BEGDA': '2018-03-15T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
    {
      'PLANS': '60000300',
      'PLSTX': 'People Partner',
      'ORGEH': '50000030',
      'STELL': '70000030',
      'BEGDA': '2009-01-12T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
  ]);

  final jobs = EntitySet(name: 'JobSet', entityType: 'Job', rows: [
    {
      'STELL': '70000010',
      'STLTX': 'Finance Analyst',
      'BEGDA': '2000-01-01T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
    {
      'STELL': '70000020',
      'STLTX': 'Software Engineer',
      'BEGDA': '2000-01-01T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
    {
      'STELL': '70000030',
      'STLTX': 'HR Generalist',
      'BEGDA': '2000-01-01T00:00:00',
      'ENDDA': '9999-12-31T00:00:00',
    },
  ]);

  final absences = EntitySet(name: 'AbsenceSet', entityType: 'Absence', rows: [
    {
      'PERNR': '00001000',
      'AWART': '0100',
      'BEGDA': '2026-04-13T00:00:00',
      'ENDDA': '2026-04-17T00:00:00',
      'ABWTG': '5.0',
    },
    {
      'PERNR': '00001001',
      'AWART': '0200',
      'BEGDA': '2026-03-02T00:00:00',
      'ENDDA': '2026-03-02T00:00:00',
      'ABWTG': '1.0',
    },
    {
      'PERNR': '00001002',
      'AWART': '0100',
      'BEGDA': '2026-05-04T00:00:00',
      'ENDDA': '2026-05-08T00:00:00',
      'ABWTG': '5.0',
    },
  ]);

  final timesheets = EntitySet(name: 'TimesheetSet', entityType: 'Timesheet', rows: [
    {
      'PERNR': '00001000',
      'WORKD': '2026-05-19T00:00:00',
      'LSTAR': 'DEV001',
      'STDAZ': '7.50',
      'KOSTL': 'CC100200',
    },
    {
      'PERNR': '00001001',
      'WORKD': '2026-05-19T00:00:00',
      'LSTAR': 'DEV001',
      'STDAZ': '8.00',
      'KOSTL': 'CC100300',
    },
    {
      'PERNR': '00001002',
      'WORKD': '2026-05-19T00:00:00',
      'LSTAR': 'HR0010',
      'STDAZ': '7.00',
      'KOSTL': 'CC100100',
    },
  ]);

  final payrollResults = EntitySet(
    name: 'PayrollResultSet',
    entityType: 'PayrollResult',
    rows: [
      {
        'PERNR': '00001000',
        'SEQNR': 1,
        'FPPER': '202604',
        'PAYTY': 'A',
        'BETRG': '3450.00',
        'WAERS': 'GBP',
      },
      {
        'PERNR': '00001001',
        'SEQNR': 1,
        'FPPER': '202604',
        'PAYTY': 'A',
        'BETRG': '4120.00',
        'WAERS': 'GBP',
      },
      {
        'PERNR': '00001002',
        'SEQNR': 1,
        'FPPER': '202604',
        'PAYTY': 'A',
        'BETRG': '38450.00',
        'WAERS': 'SEK',
      },
    ],
  );

  final wageTypes = EntitySet(name: 'WageTypeSet', entityType: 'WageType', rows: [
    {'LGART': '1000', 'LGTXT': 'Standard pay'},
    {'LGART': '1100', 'LGTXT': 'Overtime'},
    {'LGART': '2000', 'LGTXT': 'Bonus'},
  ]);

  final expenses = EntitySet(name: 'ExpenseSet', entityType: 'Expense', rows: [
    {
      'BELNR': '0000001000',
      'PERNR': '00001000',
      'BLDAT': '2026-05-10T00:00:00',
      'WRBTR': '12450.00',
      'WAERS': 'GBP',
      'KOSTL': 'CC100200',
      'SAKNR': '0000476100',
      'SGTXT': 'Client offsite — travel',
      'Status': 'SUBMITTED',
    },
    {
      'BELNR': '0000001001',
      'PERNR': '00001001',
      'BLDAT': '2026-05-12T00:00:00',
      'WRBTR': '85.40',
      'WAERS': 'GBP',
      'KOSTL': 'CC100300',
      'SAKNR': '0000476200',
      'SGTXT': 'Conference dinner',
      'Status': 'POSTED',
    },
    {
      'BELNR': '0000001002',
      'PERNR': '00001002',
      'BLDAT': '2026-05-15T00:00:00',
      'WRBTR': '2240.00',
      'WAERS': 'SEK',
      'KOSTL': 'CC100100',
      'SAKNR': '0000476300',
      'SGTXT': 'Office supplies',
      'Status': 'SUBMITTED',
    },
  ]);

  return GatewayState(services: [
    Service(
      name: 'ZHR_EMPLOYEE_SRV',
      entityTypes: [employeeType, addressType],
      entitySets: [employees, addresses],
    ),
    Service(
      name: 'ZHR_ORG_SRV',
      entityTypes: [orgUnitType, positionType, jobType],
      entitySets: [orgUnits, positions, jobs],
    ),
    Service(
      name: 'ZHR_TIME_SRV',
      entityTypes: [absenceType, timesheetType],
      entitySets: [absences, timesheets],
    ),
    Service(
      name: 'ZHR_PAYROLL_SRV',
      entityTypes: [payrollType, wageTypeType],
      entitySets: [payrollResults, wageTypes],
    ),
    Service(
      name: 'ZEXPENSE_SRV',
      entityTypes: [expenseType],
      entitySets: [expenses],
    ),
  ]);
}
