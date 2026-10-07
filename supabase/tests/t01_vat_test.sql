\set ON_ERROR_STOP 1
SET client_min_messages=warning;
CREATE SCHEMA t;
CREATE TABLE t.results(name text,ok boolean,detail text);
CREATE TABLE t.shops(tag text,result jsonb);
CREATE TABLE t.ids(tag text,id uuid);
CREATE FUNCTION t.expect(n text,b boolean,d text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ INSERT INTO t.results VALUES(n,b,d) $$;
CREATE FUNCTION t.error(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN BEGIN EXECUTE q; PERFORM t.expect(n,false,'no error'); EXCEPTION WHEN others THEN PERFORM t.expect(n,split_part(SQLERRM,':',1)=c,SQLERRM); END; END $$;
CREATE FUNCTION t.as_user(u text,o uuid DEFAULT NULL) RETURNS void LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub',COALESCE(u,''),false),set_config('app.org_id','',false),set_config('request.headers',CASE WHEN o IS NULL THEN '{}' ELSE json_build_object('x-org-id',o)::text END,false) $$;
CREATE FUNCTION t.org(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT (result->>'organization_id')::uuid FROM t.shops WHERE tag=s $$;
CREATE FUNCTION t.id(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM t.ids WHERE tag=s $$;
CREATE FUNCTION t.class(o uuid,k text) RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT id FROM public.tax_classes WHERE organization_id=o AND kind::text=k ORDER BY created_at,id LIMIT 1 $$;
GRANT USAGE ON SCHEMA t TO authenticated;
GRANT SELECT ON t.shops,t.ids TO authenticated;
GRANT INSERT ON t.results,t.ids TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO authenticated;

-- Golden cases: a copy of supabase/tests/fixtures/t01_tax_cases.json (src/test/t01-golden.test.ts keeps them equal).
CREATE TABLE t.golden(doc jsonb);
INSERT INTO t.golden VALUES ($golden$
{
  "note": "T01 golden cases (D41). Run by packages/contracts/src/tax.test.ts and supabase/tests/t01_vat_test.sql; both engines must give exactly these results. Rounding follows D31 (half-up, per line); to be confirmed with the accountant.",
  "documents": [
    {
      "id": "G01",
      "title": "Price without VAT: 100 at 14%",
      "input": {
        "prices_include_vat": false,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "100.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "100.00",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "100.00",
            "tax": "14.00",
            "gross": "114.00"
          }
        ],
        "subtotal": "100.00",
        "discount_total": "0.00",
        "net_total": "100.00",
        "tax_total": "14.00",
        "total": "114.00"
      }
    },
    {
      "id": "G02",
      "title": "Price with VAT: 114 at 14%",
      "input": {
        "prices_include_vat": true,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "114.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "114.00",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "100.00",
            "tax": "14.00",
            "gross": "114.00"
          }
        ],
        "subtotal": "114.00",
        "discount_total": "0.00",
        "net_total": "100.00",
        "tax_total": "14.00",
        "total": "114.00"
      }
    },
    {
      "id": "G03",
      "title": "Price with VAT, net rounds: 100 at 14%",
      "input": {
        "prices_include_vat": true,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "100.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "100.00",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "87.72",
            "tax": "12.28",
            "gross": "100.00"
          }
        ],
        "subtotal": "100.00",
        "discount_total": "0.00",
        "net_total": "87.72",
        "tax_total": "12.28",
        "total": "100.00"
      }
    },
    {
      "id": "G04",
      "title": "Half-up on the tax: net 0.25 at 14% (0.035)",
      "input": {
        "prices_include_vat": false,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "0.25",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "0.25",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "0.25",
            "tax": "0.04",
            "gross": "0.29"
          }
        ],
        "subtotal": "0.25",
        "discount_total": "0.00",
        "net_total": "0.25",
        "tax_total": "0.04",
        "total": "0.29"
      }
    },
    {
      "id": "G05",
      "title": "Price with VAT, net rounds down: 10.00 at 14%",
      "input": {
        "prices_include_vat": true,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "10.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "10.00",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "8.77",
            "tax": "1.23",
            "gross": "10.00"
          }
        ],
        "subtotal": "10.00",
        "discount_total": "0.00",
        "net_total": "8.77",
        "tax_total": "1.23",
        "total": "10.00"
      }
    },
    {
      "id": "G06",
      "title": "Quantity: 3 x 33.33 without VAT",
      "input": {
        "prices_include_vat": false,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "33.33",
            "quantity": 3,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "99.99",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "99.99",
            "tax": "14.00",
            "gross": "113.99"
          }
        ],
        "subtotal": "99.99",
        "discount_total": "0.00",
        "net_total": "99.99",
        "tax_total": "14.00",
        "total": "113.99"
      }
    },
    {
      "id": "G07",
      "title": "Tax is per line, not on the total: two lines of 0.25",
      "input": {
        "prices_include_vat": false,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "0.25",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          },
          {
            "unit_price": "0.25",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "0.25",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "0.25",
            "tax": "0.04",
            "gross": "0.29"
          },
          {
            "line_amount": "0.25",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "0.25",
            "tax": "0.04",
            "gross": "0.29"
          }
        ],
        "subtotal": "0.50",
        "discount_total": "0.00",
        "net_total": "0.50",
        "tax_total": "0.08",
        "total": "0.58"
      }
    },
    {
      "id": "G08",
      "title": "Mixed classes: standard, zero-rated, exempt",
      "input": {
        "prices_include_vat": false,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "100.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          },
          {
            "unit_price": "50.00",
            "quantity": 1,
            "tax_rate": "0",
            "line_discount": "0.00"
          },
          {
            "unit_price": "30.00",
            "quantity": 1,
            "tax_rate": "0",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "100.00",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "100.00",
            "tax": "14.00",
            "gross": "114.00"
          },
          {
            "line_amount": "50.00",
            "discount_amount": "0.00",
            "tax_rate": "0",
            "net": "50.00",
            "tax": "0.00",
            "gross": "50.00"
          },
          {
            "line_amount": "30.00",
            "discount_amount": "0.00",
            "tax_rate": "0",
            "net": "30.00",
            "tax": "0.00",
            "gross": "30.00"
          }
        ],
        "subtotal": "180.00",
        "discount_total": "0.00",
        "net_total": "180.00",
        "tax_total": "14.00",
        "total": "194.00"
      }
    },
    {
      "id": "G09",
      "title": "Line discount before tax: 200 less 20",
      "input": {
        "prices_include_vat": false,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "200.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "20.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "200.00",
            "discount_amount": "20.00",
            "tax_rate": "14",
            "net": "180.00",
            "tax": "25.20",
            "gross": "205.20"
          }
        ],
        "subtotal": "200.00",
        "discount_total": "20.00",
        "net_total": "180.00",
        "tax_total": "25.20",
        "total": "205.20"
      }
    },
    {
      "id": "G10",
      "title": "Document discount spread by amount: 40 over 100 and 300",
      "input": {
        "prices_include_vat": false,
        "document_discount": "40.00",
        "lines": [
          {
            "unit_price": "100.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          },
          {
            "unit_price": "300.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "100.00",
            "discount_amount": "10.00",
            "tax_rate": "14",
            "net": "90.00",
            "tax": "12.60",
            "gross": "102.60"
          },
          {
            "line_amount": "300.00",
            "discount_amount": "30.00",
            "tax_rate": "14",
            "net": "270.00",
            "tax": "37.80",
            "gross": "307.80"
          }
        ],
        "subtotal": "400.00",
        "discount_total": "40.00",
        "net_total": "360.00",
        "tax_total": "50.40",
        "total": "410.40"
      }
    },
    {
      "id": "G11",
      "title": "Document discount with leftover piasters: 10 over three lines, prices with VAT",
      "input": {
        "prices_include_vat": true,
        "document_discount": "10.00",
        "lines": [
          {
            "unit_price": "100.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          },
          {
            "unit_price": "100.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          },
          {
            "unit_price": "100.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "100.00",
            "discount_amount": "3.34",
            "tax_rate": "14",
            "net": "84.79",
            "tax": "11.87",
            "gross": "96.66"
          },
          {
            "line_amount": "100.00",
            "discount_amount": "3.33",
            "tax_rate": "14",
            "net": "84.80",
            "tax": "11.87",
            "gross": "96.67"
          },
          {
            "line_amount": "100.00",
            "discount_amount": "3.33",
            "tax_rate": "14",
            "net": "84.80",
            "tax": "11.87",
            "gross": "96.67"
          }
        ],
        "subtotal": "300.00",
        "discount_total": "10.00",
        "net_total": "254.39",
        "tax_total": "35.61",
        "total": "290.00"
      }
    },
    {
      "id": "G12",
      "title": "Document discount over standard and zero-rated lines, prices with VAT",
      "input": {
        "prices_include_vat": true,
        "document_discount": "21.40",
        "lines": [
          {
            "unit_price": "114.00",
            "quantity": 1,
            "tax_rate": "14",
            "line_discount": "0.00"
          },
          {
            "unit_price": "100.00",
            "quantity": 1,
            "tax_rate": "0",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "114.00",
            "discount_amount": "11.40",
            "tax_rate": "14",
            "net": "90.00",
            "tax": "12.60",
            "gross": "102.60"
          },
          {
            "line_amount": "100.00",
            "discount_amount": "10.00",
            "tax_rate": "0",
            "net": "90.00",
            "tax": "0.00",
            "gross": "90.00"
          }
        ],
        "subtotal": "214.00",
        "discount_total": "21.40",
        "net_total": "180.00",
        "tax_total": "12.60",
        "total": "192.60"
      }
    },
    {
      "id": "G13",
      "title": "Large values: 12 x 18999.99 with VAT",
      "input": {
        "prices_include_vat": true,
        "document_discount": "0.00",
        "lines": [
          {
            "unit_price": "18999.99",
            "quantity": 12,
            "tax_rate": "14",
            "line_discount": "0.00"
          }
        ]
      },
      "expected": {
        "lines": [
          {
            "line_amount": "227999.88",
            "discount_amount": "0.00",
            "tax_rate": "14",
            "net": "199999.89",
            "tax": "27999.99",
            "gross": "227999.88"
          }
        ],
        "subtotal": "227999.88",
        "discount_total": "0.00",
        "net_total": "199999.89",
        "tax_total": "27999.99",
        "total": "227999.88"
      }
    }
  ],
  "returns": [
    {
      "id": "R01",
      "title": "Full return of a 2-unit line",
      "original": {
        "quantity": 2,
        "net": "200.00",
        "tax": "28.00",
        "gross": "228.00"
      },
      "expected": [
        {
          "quantity": 2,
          "net": "200.00",
          "tax": "28.00",
          "gross": "228.00"
        }
      ]
    },
    {
      "id": "R02",
      "title": "Three single returns of a 3-unit line add back exactly",
      "original": {
        "quantity": 3,
        "net": "100.00",
        "tax": "14.00",
        "gross": "114.00"
      },
      "expected": [
        {
          "quantity": 1,
          "net": "33.33",
          "tax": "4.67",
          "gross": "38.00"
        },
        {
          "quantity": 1,
          "net": "33.33",
          "tax": "4.67",
          "gross": "38.00"
        },
        {
          "quantity": 1,
          "net": "33.34",
          "tax": "4.66",
          "gross": "38.00"
        }
      ]
    },
    {
      "id": "R03",
      "title": "Partial then the rest",
      "original": {
        "quantity": 5,
        "net": "87.72",
        "tax": "12.28",
        "gross": "100.00"
      },
      "expected": [
        {
          "quantity": 2,
          "net": "35.09",
          "tax": "4.91",
          "gross": "40.00"
        },
        {
          "quantity": 3,
          "net": "52.63",
          "tax": "7.37",
          "gross": "60.00"
        }
      ]
    }
  ]
}
$golden$::jsonb);
SELECT t.expect('golden '||(c->>'id')||': '||(c->>'title'), app.compute_document_tax(c->'input')=c->'expected', app.compute_document_tax(c->'input')::text)
FROM t.golden g, jsonb_array_elements(g.doc->'documents') c;
DO $$
DECLARE r jsonb; s jsonb; q int; tx numeric; gr numeric; got jsonb;
BEGIN
  FOR r IN SELECT jsonb_array_elements(doc->'returns') FROM t.golden LOOP
    q:=0; tx:=0; gr:=0;
    FOR s IN SELECT jsonb_array_elements(r->'expected') LOOP
      got:=app.return_line_tax((r#>>'{original,quantity}')::int,(r#>>'{original,tax}')::numeric,(r#>>'{original,gross}')::numeric,q,tx,gr,(s->>'quantity')::int);
      PERFORM t.expect('golden '||(r->>'id')||' return of '||(s->>'quantity')||': '||(r->>'title'),got=(s-'quantity'),got::text);
      q:=q+(s->>'quantity')::int; tx:=tx+(s->>'tax')::numeric; gr:=gr+(s->>'gross')::numeric;
    END LOOP;
  END LOOP;
END $$;
SELECT t.error('discount above the amount',$q$SELECT app.compute_document_tax('{"prices_include_vat":false,"document_discount":"101.00","lines":[{"unit_price":"100.00","quantity":1,"tax_rate":"14"}]}')$q$,'TAX_DISCOUNT_TOO_LARGE');
SELECT t.error('line discount above the line',$q$SELECT app.compute_document_tax('{"prices_include_vat":false,"lines":[{"unit_price":"10.00","quantity":1,"line_discount":"11.00","tax_rate":"14"}]}')$q$,'TAX_DISCOUNT_TOO_LARGE');
SELECT t.error('price with 3 decimals',$q$SELECT app.compute_document_tax('{"prices_include_vat":false,"lines":[{"unit_price":"1.005","quantity":1,"tax_rate":"14"}]}')$q$,'VALIDATION_FAILED');
SELECT t.error('return more than left',$q$SELECT app.return_line_tax(2,28,228,1,14,114,2)$q$,'VALIDATION_FAILED');

-- Shops a and b (retail).
SELECT t.as_user('f0000000-0000-0000-0000-000000000001');
INSERT INTO t.shops SELECT s,public.admin_provision_organization('T01 '||s,'t01-'||s,'retail','Owner',s||'@example.com',NULL,'Main',h,now()+interval '1 day') FROM (VALUES('a',repeat('g',64)),('b',repeat('h',64)))v(s,h);
INSERT INTO auth.users(id,email) VALUES('a0400000-0000-4000-8000-000000000001','a@example.com'),('a0400000-0000-4000-8000-000000000002','b@example.com'),('a0400000-0000-4000-8000-000000000003','cashier@example.com');
SELECT public.accept_invite(repeat('g',64),'a0400000-0000-4000-8000-000000000001');
SELECT public.accept_invite(repeat('h',64),'a0400000-0000-4000-8000-000000000002');
INSERT INTO public.employees(organization_id,auth_user_id,full_name,role) VALUES(t.org('a'),'a0400000-0000-4000-8000-000000000003','Cashier','CASHIER');
SELECT t.expect('new shop gets three default classes',(SELECT count(*)=3 AND count(*) FILTER(WHERE kind='standard' AND rate=14)=1 AND count(*) FILTER(WHERE kind<>'standard' AND rate=0)=2 FROM public.tax_classes WHERE organization_id=t.org('a')));
SELECT t.expect('standard class is the default and the delivery fee class',(SELECT default_tax_class_id=t.class(t.org('a'),'standard') AND delivery_fee_tax_class_id=t.class(t.org('a'),'standard') AND installment_markup_vat='not_taxed' AND deposit_vat_timing='on_delivery' FROM public.org_settings WHERE organization_id=t.org('a')));
SELECT t.expect('existing shops were backfilled',NOT EXISTS(SELECT 1 FROM public.org_settings s WHERE s.default_tax_class_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.tax_classes c WHERE c.organization_id=s.organization_id)));

SELECT t.as_user('a0400000-0000-4000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
INSERT INTO t.ids VALUES('reduced',public.create_tax_class(' Reduced 5% ','standard',5,'T1','V010'));
SELECT t.error('name taken',$q$SELECT public.create_tax_class('Reduced 5%','standard',5,'T1','V010')$q$,'TAX_CLASS_NAME_TAKEN');
SELECT t.error('zero class must be 0%',$q$SELECT public.create_tax_class('Bad zero','zero',5,'T1','V001')$q$,'VALIDATION_FAILED');
SELECT t.error('blank name',$q$SELECT public.create_tax_class(' ','standard',5,'T1','V009')$q$,'NAME_REQUIRED');
SELECT t.error('rate above 100',$q$SELECT public.create_tax_class('Huge','standard',101,'T1','V009')$q$,'VALIDATION_FAILED');
SELECT t.error('kind change to zero keeps rate 5',format('SELECT public.update_tax_class(%L,%L)',t.id('reduced'),'{"kind":"zero"}'),'VALIDATION_FAILED');
SELECT t.error('foreign class update',format('SELECT public.update_tax_class(%L,%L)',t.class(t.org('b'),'standard'),'{"rate":"10"}'),'TAX_CLASS_NOT_FOUND');
SELECT t.error('foreign class archive',format('SELECT public.set_tax_class_archived(%L,true)',t.class(t.org('b'),'standard')),'TAX_CLASS_NOT_FOUND');
SELECT t.error('default class cannot be archived',format('SELECT public.set_tax_class_archived(%L,true)',t.class(t.org('a'),'standard')),'TAX_CLASS_IN_USE');
SELECT public.set_tax_class_archived(t.class(t.org('a'),'exempt'),true);
SELECT t.expect('list shows archived last',(SELECT (l->-1->>'kind')='exempt' AND (l->-1->>'archived_at') IS NOT NULL AND jsonb_array_length(l)=4 FROM public.list_tax_classes() l));
SELECT public.set_tax_class_archived(t.class(t.org('a'),'exempt'),false);
SELECT public.update_org_settings(jsonb_build_object('installment_markup_vat','taxed','deposit_vat_timing','on_deposit','delivery_fee_tax_class_id',t.id('reduced')));
SELECT t.expect('accountant settings saved',(SELECT s->>'installment_markup_vat'='taxed' AND s->>'deposit_vat_timing'='on_deposit' AND s->>'delivery_fee_tax_class_id'=t.id('reduced')::text FROM public.get_shop_settings() s));
SELECT t.error('bad markup setting',$q$SELECT public.update_org_settings('{"installment_markup_vat":"sometimes"}')$q$,'SETTINGS_INVALID');
SELECT t.error('foreign delivery fee class',format('SELECT public.update_org_settings(%L)',jsonb_build_object('delivery_fee_tax_class_id',t.class(t.org('b'),'standard'))),'TAX_CLASS_NOT_FOUND');
SELECT t.error('delivery fee class cannot be archived',format('SELECT public.set_tax_class_archived(%L,true)',t.id('reduced')),'TAX_CLASS_IN_USE');
RESET ROLE;
SELECT t.expect('tax class changes audited',(SELECT count(*) FILTER(WHERE action='tax_class.created')=1 AND count(*) FILTER(WHERE action='tax_class.archived')=1 AND count(*) FILTER(WHERE action='tax_class.restored')=1 FROM public.audit_log WHERE organization_id=t.org('a')));

-- Done when: a rate change doesn't alter old documents (issued sale lines keep their snapshot).
INSERT INTO public.products(organization_id,name_ar,sku,cash_price,tax_class_id,is_serialized) VALUES(t.org('a'),'Product','T01-P',114,t.id('reduced'),false) RETURNING id AS product_id \gset
INSERT INTO public.sales(organization_id,number,branch_id,prices_include_vat,subtotal,tax_total,total,business_date,idempotency_key)
SELECT t.org('a'),'T01-SL-1',(SELECT id FROM public.branches WHERE organization_id=t.org('a') AND is_main),true,114,5.43,114,CURRENT_DATE,'t01-sale-0001' RETURNING id AS sale_id \gset
INSERT INTO public.sale_lines(organization_id,sale_id,line_no,product_id,quantity,unit_price,tax_class_id,tax_rate,tax_amount,line_total)
VALUES(t.org('a'),:'sale_id',1,:'product_id',1,114,t.id('reduced'),5,5.43,114);
SELECT t.as_user('a0400000-0000-4000-8000-000000000001',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT public.update_tax_class(t.id('reduced'),'{"rate":"7.5"}');
SELECT t.error('class used by an active product cannot be archived',format('SELECT public.set_tax_class_archived(%L,true)',t.id('reduced')),'TAX_CLASS_IN_USE');
RESET ROLE;
SELECT t.expect('rate change keeps issued lines',(SELECT tax_rate=5 AND tax_amount=5.43 FROM public.sale_lines WHERE sale_id=:'sale_id') AND (SELECT tax_total=5.43 FROM public.sales WHERE id=:'sale_id') AND (SELECT rate=7.5 FROM public.tax_classes WHERE id=t.id('reduced')));
SELECT t.expect('rate change audited with before and after',EXISTS(SELECT 1 FROM public.audit_log WHERE action='tax_class.updated' AND entity_id=t.id('reduced') AND before->>'rate'='5.00' AND after->>'rate'='7.50'));

-- Cashier reads but can't manage.
SELECT t.as_user('a0400000-0000-4000-8000-000000000003',t.org('a'));
SET LOCAL ROLE authenticated;
SELECT t.expect('cashier lists classes',(SELECT jsonb_array_length(l)=4 FROM public.list_tax_classes() l));
SELECT t.error('cashier cannot create',$q$SELECT public.create_tax_class('Cashier class','standard',1,'T1','V009')$q$,'PERMISSION_DENIED');
RESET ROLE;
SELECT t.expect('new RPCs no anon grants',NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN('list_tax_classes','create_tax_class','update_tax_class','set_tax_class_archived') AND has_function_privilege('anon',oid,'EXECUTE')));
SELECT t.expect('engine helpers not granted',NOT EXISTS(SELECT 1 FROM pg_proc WHERE pronamespace='app'::regnamespace AND proname IN('compute_document_tax','return_line_tax','seed_tax_classes','tax_class_json') AND has_function_privilege('authenticated',oid,'EXECUTE')));
SELECT name,ok,detail FROM t.results WHERE NOT COALESCE(ok,false);
SELECT count(*) FILTER(WHERE ok) passed,count(*) FILTER(WHERE NOT COALESCE(ok,false)) failed FROM t.results;
