#!/usr/bin/env python3
from pathlib import Path
import argparse,uuid,xml.etree.ElementTree as ET
D='www.microsoft.com/SqlServer/Dts'; S='www.microsoft.com/sqlserver/dts/tasks/sqltask'; ET.register_namespace('DTS',D); ET.register_namespace('SQLTask',S)
q=lambda n,k:f'{{{n}}}{k}'; uid=lambda:'{'+str(uuid.uuid4()).upper()+'}'
def main():
 a=argparse.ArgumentParser(); a.add_argument('--output',required=True); o=a.parse_args(); cid=uid()
 r=ET.Element(q(D,'Executable'),{q(D,'refId'):'Package',q(D,'CreationName'):'Microsoft.Package',q(D,'DTSID'):uid(),q(D,'ExecutableType'):'Microsoft.Package',q(D,'LastModifiedProductVersion'):'16.0.4215.2',q(D,'LocaleID'):'1033',q(D,'ObjectName'):'00_Master_NYC311_ETL',q(D,'PackageType'):'5',q(D,'VersionBuild'):'1',q(D,'VersionGUID'):uid(),q(D,'ProtectionLevel'):'0'})
 p=ET.SubElement(r,q(D,'Property'),{q(D,'Name'):'PackageFormatVersion'}); p.text='8'; cms=ET.SubElement(r,q(D,'ConnectionManagers')); cm=ET.SubElement(cms,q(D,'ConnectionManager'),{q(D,'refId'):'Package.ConnectionManagers[NYC311_DW]',q(D,'CreationName'):'OLEDB',q(D,'DTSID'):cid,q(D,'ObjectName'):'NYC311_DW'}); od=ET.SubElement(cm,q(D,'ObjectData')); ET.SubElement(od,q(D,'ConnectionManager'),{q(D,'ConnectRetryCount'):'3',q(D,'ConnectRetryInterval'):'2',q(D,'ConnectionString'):'Provider=MSOLEDBSQL;Data Source=localhost;Initial Catalog=NYC311_DW;User ID=sa;Password=RUNTIME_OVERRIDE;Encrypt=Optional;TrustServerCertificate=True;'})
 ET.SubElement(r,q(D,'Variables')); xs=ET.SubElement(r,q(D,'Executables')); steps=[('01 - Begin ETL batch','EXEC etl.usp_BeginBatch;'),('02 - Extract/load CSV to staging','EXEC etl.usp_LoadStaging;'),('03 - Transform/load dimensions','EXEC etl.usp_LoadDimensions;'),('04 - Transform/load fact','EXEC etl.usp_LoadFact;'),('05 - Validate and close batch','EXEC etl.usp_ValidateAndCloseBatch;')]; refs=[]
 for name,sql in steps:
  ref='Package\\'+name; refs.append(ref); x=ET.SubElement(xs,q(D,'Executable'),{q(D,'refId'):ref,q(D,'CreationName'):'Microsoft.ExecuteSQLTask',q(D,'Description'):'Execute SQL Task',q(D,'DTSID'):uid(),q(D,'ExecutableType'):'Microsoft.ExecuteSQLTask',q(D,'LocaleID'):'-1',q(D,'ObjectName'):name,q(D,'TaskContact'):'Execute SQL Task; Microsoft Corporation; SQL Server 2022;1',q(D,'ThreadHint'):'0'}); ET.SubElement(x,q(D,'Variables')); oo=ET.SubElement(x,q(D,'ObjectData')); ET.SubElement(oo,q(S,'SqlTaskData'),{q(S,'Connection'):cid,q(S,'SqlStatementSource'):sql})
 pcs=ET.SubElement(r,q(D,'PrecedenceConstraints'))
 for i in range(4): ET.SubElement(pcs,q(D,'PrecedenceConstraint'),{q(D,'refId'):f'Package.PrecedenceConstraints[Constraint {i+1}]',q(D,'CreationName'):'',q(D,'DTSID'):uid(),q(D,'From'):refs[i],q(D,'LogicalAnd'):'True',q(D,'ObjectName'):f'Constraint {i+1}',q(D,'To'):refs[i+1]})
 t=ET.ElementTree(r); ET.indent(t,space='  '); out=Path(o.output); out.parent.mkdir(parents=True,exist_ok=True); t.write(out,encoding='utf-8',xml_declaration=True); print(f'[PASS] Wrote {out}')
if __name__=='__main__':main()
