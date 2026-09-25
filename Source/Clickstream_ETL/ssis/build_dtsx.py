#!/usr/bin/env python3
import argparse
from pathlib import Path
from xml.etree.ElementTree import Element, SubElement, ElementTree

DTS = "www.microsoft.com/SqlServer/Dts"
SQL = "www.microsoft.com/sqlserver/dts/tasks/sqltask"
NS_DTS = f"{{{DTS}}}"
NS_SQL = f"{{{SQL}}}"

TASKS = [
    ("Task_01_Begin_ETL_Batch", "EXEC etl.usp_BeginBatch;"),
    ("Task_02_Load_Staging", "EXEC etl.usp_LoadStaging;"),
    ("Task_03_Load_Dimensions", "EXEC etl.usp_LoadDimensions;"),
    ("Task_04_Load_Fact", "EXEC etl.usp_LoadFact;"),
    ("Task_05_Validate_And_Close_Batch", "EXEC etl.usp_ValidateAndCloseBatch;"),
]

def qname(ns, name): return f"{{{ns}}}{name}"

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--output",required=True)
    args=ap.parse_args()
    out=Path(args.output)
    out.parent.mkdir(parents=True,exist_ok=True)

    root=Element(qname(DTS,"Executable"),{
        qname(DTS,"ExecutableType"):"Microsoft.Package",
        qname(DTS,"ObjectName"):"Master_Clickstream_ETL",
        qname(DTS,"DTSID"):"{11111111-1111-1111-1111-111111111111}",
        qname(DTS,"CreationName"):"Microsoft.Package"
    })
    SubElement(root,qname(DTS,"Property"),{qname(DTS,"Name"):"PackageFormatVersion"}).text="8"

    cms=SubElement(root,qname(DTS,"ConnectionManagers"))
    cm=SubElement(cms,qname(DTS,"ConnectionManager"),{
        qname(DTS,"ObjectName"):"ClickstreamDW",
        qname(DTS,"DTSID"):"{22222222-2222-2222-2222-222222222222}",
        qname(DTS,"CreationName"):"ADO.NET:System.Data.SqlClient.SqlConnection, System.Data, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"
    })
    SubElement(cm,qname(DTS,"ObjectData")).append(
        Element(qname(DTS,"ConnectionManager"),{
            qname(DTS,"ConnectionString"):"Data Source=localhost;Initial Catalog=ClickstreamDW;User ID=sa;Password=__RUNTIME_OVERRIDE__;TrustServerCertificate=True;"
        })
    )

    exes=SubElement(root,qname(DTS,"Executables"))
    ids=[]
    for i,(name,sql) in enumerate(TASKS,1):
        tid=f"{{33333333-3333-3333-3333-{i:012d}}}"
        ids.append(tid)
        e=SubElement(exes,qname(DTS,"Executable"),{
            qname(DTS,"ExecutableType"):"Microsoft.SqlServer.Dts.Tasks.ExecuteSQLTask.ExecuteSQLTask, Microsoft.SqlServer.SQLTask, Version=16.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91",
            qname(DTS,"ObjectName"):name,
            qname(DTS,"DTSID"):tid,
            qname(DTS,"CreationName"):"Microsoft.SqlServer.Dts.Tasks.ExecuteSQLTask.ExecuteSQLTask, Microsoft.SqlServer.SQLTask, Version=16.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"
        })
        od=SubElement(e,qname(DTS,"ObjectData"))
        st=SubElement(od,qname(SQL,"SqlTaskData"),{
            qname(SQL,"Connection"):"ClickstreamDW",
            qname(SQL,"SqlStatementSource"):sql,
            qname(SQL,"SqlStatementSourceType"):"DirectInput",
            qname(SQL,"ResultType"):"ResultSetType_None"
        })

    pcs=SubElement(root,qname(DTS,"PrecedenceConstraints"))
    for i in range(4):
        SubElement(pcs,qname(DTS,"PrecedenceConstraint"),{
            qname(DTS,"From"):ids[i],qname(DTS,"To"):ids[i+1],
            qname(DTS,"Value"):"0",qname(DTS,"EvalOp"):"1",
            qname(DTS,"DTSID"):f"{{44444444-4444-4444-4444-{i+1:012d}}}"
        })

    ElementTree(root).write(out,encoding="utf-8",xml_declaration=True)
    print(f"[PASS] generated {out}")

if __name__=="__main__":
    main()
