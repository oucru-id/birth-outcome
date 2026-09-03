"""Build editable Graphviz sources for the documented SQL dependency paths.

Run this script, then render_diagrams.cjs with @viz-js/viz and sharp available.
These are documentation diagrams, not an executable scheduler or complete SQL DAG.
"""
from pathlib import Path
import json
import textwrap

OUT = Path(__file__).resolve().parent

def label(text, width=35):
    lines = []
    for line in text.splitlines():
        if ' ' not in line and '_' in line and len(line) > width:
            chunks, current = [], ''
            parts = line.split('_')
            for i, part in enumerate(parts):
                token = part + ('_' if i < len(parts)-1 else '')
                if current and len(current + token) > width:
                    chunks.append(current); current = ''
                current += token
            lines.extend(chunks + [current])
        else:
            lines.extend(textwrap.wrap(line, width=width, break_long_words=False,
                                       break_on_hyphens=False) or [''])
    return json.dumps("\n".join(lines), ensure_ascii=False)

def node(key, text, kind="table", width=35):
    colors = {"raw": "#F1F3F5", "view": "#E8EFF8", "table": "#E8F2EE",
              "step": "#FFF2DF", "external": "#F8EDF0", "output": "#DCEBF5"}
    style = "rounded,filled,dashed" if kind == "external" else "rounded,filled"
    return f'{key} [label={label(text,width)}, fillcolor="{colors[kind]}", style="{style}"];\n'

def edge(a, b, caption=None, dashed=False):
    attrs = []
    if caption: attrs.append(f'label={label(caption)}')
    if dashed: attrs.append('style="dashed"')
    return f'{a} -> {b}' + (' [' + ', '.join(attrs) + ']' if attrs else '') + ';\n'

def group(key, title, content, color):
    return f'subgraph cluster_{key} {{ label={label(title)}; color="{color}"; penwidth=1.5; style="rounded"; bgcolor="#FAFCFE";\n{content}}}\n'

def graph(content):
    return '''digraph pipeline {
graph [rankdir=TB, bgcolor="white", fontname="DejaVu Sans", fontsize=14,
       nodesep=0.26, ranksep=0.40, pad=0.14, compound=true, newrank=true];
node [shape=box, fontname="DejaVu Sans", fontsize=11, color="#60768A",
      penwidth=0.8, margin="0.14,0.09"];
edge [fontname="DejaVu Sans", fontsize=9, color="#60768A", arrowsize=0.7];
''' + content + '}\n'

sig_raw = "raw_data\nsigizi_kesga_bumil_anc\nsigizi_daftar_ibu\nsigizi_daftar_ibu_hamil\nsigizi_kohort_ibu\nsigizi_ibu_nifas"
sig_views = "vs_sigizi_anc\nvs_sigizi_daftar_ibu\nvs_sigizi_daftar_ibu_hamil\nvs_sigizi_kohort_ibu\nvs_sigizi_kohort_nifas"
epus_raw = "raw_data\nepus_anc\nepus_inc\nepus_pnc\nepus_kunjungan_ibu_hamil"
epus_views = "vs_epus_anc\nvs_epus_inc\nvs_epus_pnc\nvs_kohort_epus_kunjungan_ibu_hamil"

sig = (node('sr', sig_raw, 'raw', width=27) + node('sv', sig_views, 'view', width=27)
    + node('dr', 'raw_data\nsigizi_bumil_hapus_new', 'raw', width=24)
    + node('dv', 'vs_sigizi_bumil_hapus\nDeletion registry', 'view', width=24)
    + node('gate', '03_sigizi_source.sql\nExclude matching deleted pregnancies', 'step', width=27)
    + node('ss', 't_sigizi_source_records\nActive SIGIZI records')
    + node('geo', '03a_sigizi_geography.sql\nCorrect geography in the same source table', 'step')
    + edge('sr','sv') + edge('sv','gate') + edge('dr','dv')
    + edge('dv','gate','exclusion reference') + edge('gate','ss') + edge('ss','geo'))
epus = (node('er', epus_raw, 'raw') + node('ev', epus_views, 'view')
    + node('es', 't_epus_source_records')
    + node('eprep', 'Mother identity, pregnancy assignment and ANC deduplication', 'step')
    + node('em', 't_epus_pregnancy_master')
    + edge('er','ev') + edge('ev','es') + edge('es','eprep') + edge('eprep','em')
    + edge('ev','em','INC evidence'))
sg = group('sigizi', 'SIGIZI | pregnancy and outcome records', sig, '#388E73')
eg = group('epus', 'EPUS | visits, pregnancy and delivery', epus, '#397BB6')

sim = (node('mr','raw_data.simrs_patut_patuh_inc','raw')
    + node('mv','vs_simrs_patut_patuh_inc','view') + edge('mr','mv'))
kobo = (node('kr','data_kobo_form\ne-form_pencatatan_pelayanan_intranatal_care','raw')
    + node('ka','data_adjudication.adj_final','raw')
    + node('kv','vs_kobo_inc_submission_clean','view')
    + node('kc','vs_kobo_inc_case_master','view')
    + node('kn','data_kobo_form.neonatus_outcome_v2','raw')
    + node('kb','vs_kobo_neonatus_outcome_v2_baby','view')
    + edge('kr','kv') + edge('kv','kc') + edge('ka','kc') + edge('kn','kb'))
facility = (node('fr','Facility birth reporting\nRaw ingestion / tracker build not defined in this repository','external')
    + node('fv','birth_report_faskes.v_inc_report_tracker','view')
    + edge('fr','fv','external boundary',True))
mg = group('simrs','SIMRS | hospital births',sim,'#7B69AE')
kg = group('kobo','Kobo | INC cases and neonatal outcomes',kobo,'#C08C31')
fg = group('facility','Facility birth reports | external',facility,'#B4697E')

preg_join = (node('episodes','SIGIZI episodes + EPUS episode adapter\nWithin-source and cross-source canonicalization','step')
    + node('sp','t_pregnancy_episode_spine_v3_3')
    + edge('geo','episodes') + edge('em','episodes') + edge('episodes','sp'))
evidence = node('oe','t_pregnancy_outcome_events_v3_3')
source_edges = ''.join(edge(x,'oe') for x in ['geo','em','mv','kc','kb','fv'])

# Word panel: pregnancy-source families, retaining the output split.
preg_panel = sg + eg + '{rank=same; sr; er;} {rank=same; sv; ev;}\n'
(OUT/'pregnancy_sources.dot').write_text(graph(preg_panel))
(OUT/'sigizi_sources.dot').write_text(graph(sg))
(OUT/'epus_sources.dot').write_text(graph(eg))

# Dedicated deletion view: the exclusion decision branches before publication.
deletion = (node('clinical', 'SIGIZI clinical cleaning views', 'view')
    + node('deleted_raw', 'raw_data.sigizi_bumil_hapus_new', 'raw')
    + node('deleted_view', 'vs_sigizi_bumil_hapus', 'view')
    + node('check', '03_sigizi_source.sql\nSame mother identity AND same pregnancy anchor?', 'step')
    + node('active', 't_sigizi_source_records\nRetained clinical source records')
    + node('audit', 't_sigizi_deletion_exclusion_audit\nExcluded rows and matching references')
    + node('next', '03a geography correction\nThen pregnancy and outcome builders', 'step')
    + edge('deleted_raw','deleted_view') + edge('deleted_view','check')
    + edge('clinical','check') + edge('check','audit','match')
    + edge('check','active','no qualifying match') + edge('active','next')
    + '{rank=same; clinical; deleted_view;} {rank=same; active; audit;}\n')
(OUT/'sigizi_deletion_exclusion.dot').write_text(graph(deletion))

# Word panel: other source families. Keep the output at the bottom.
other_panel = mg + kg + fg + evidence + ''.join(edge(x,'oe') for x in ['mv','kc','kb','fv'])
(OUT/'other_sources.dot').write_text(graph(other_panel))
(OUT/'simrs_facility_sources.dot').write_text(graph(mg + fg + evidence
    + edge('mv','oe') + edge('fv','oe') + '{rank=same; mr; fr;}\n'))
(OUT/'kobo_sources.dot').write_text(graph(kg + evidence + edge('kc','oe') + edge('kb','oe')
    + 'kr -> ka [style=invis]; ka -> kv [style=invis]; {rank=same; kr; kn;}\n'))

def core(include_inputs=True):
    content = ''
    if include_inputs:
        content += node('sp','t_pregnancy_episode_spine_v3_3') + evidence
    content += (node('usg','t_pregnancy_usg_dating_v3_3')
        + node('anc','vs_epus_anc\nUSG observations','view')
        + node('tracking','t_pregnancy_outcome_tracking_v3_3')
        + node('ds','t_delivery_source_records')
        + node('db','t_delivery_dedup_base')
        + node('du','t_delivery_event_master_unlinked')
        + node('match','Delivery-to-pregnancy matching\nTiming, ambiguity and collision checks','step')
        + node('dm','t_delivery_event_master_v3')
        + node('valid','v_delivery_event_master_validated','view')
        + node('pi','v_pregnancy_monitoring_integrated','view')
        + node('scope','v_pregnancy_monitoring_by_source_scope','view')
        + node('di','v_delivery_monitoring_integrated','view')
        + node('pl','Looker | pregnancy monitoring','output')
        + node('dl','Looker | delivery and ANC linkage','output'))
    for a,b in [('sp','usg'),('anc','usg'),('sp','tracking'),('usg','tracking'),('oe','tracking'),
                ('oe','ds'),('ds','db'),('db','du'),('du','match'),('sp','match'),('match','dm'),
                ('dm','valid'),('tracking','pi'),('valid','pi'),('valid','di'),('pi','scope'),
                ('scope','pl'),('di','dl')]:
        content += edge(a,b)
    return content

(OUT/'core_reporting.dot').write_text(graph(core()))
compact_kobo = group('kobo', 'Kobo | INC and neonatal outcomes',
    node('kraw', 'data_kobo_form\ne-form_pencatatan_pelayanan_intranatal_care\nneonatus_outcome_v2\n\ndata_adjudication.adj_final', 'raw')
    + node('kviews', 'vs_kobo_inc_submission_clean\nvs_kobo_inc_case_master\nvs_kobo_neonatus_outcome_v2_baby', 'view')
    + edge('kraw','kviews','see Kobo detail'), '#C08C31')
full_edges = ''.join(edge(x,'oe') for x in ['geo','em','mv','kviews','fv'])
full = sg + eg + mg + compact_kobo + fg + preg_join + evidence + full_edges + core(False)
full += '{rank=same; sr; er; mr; kraw; fr;}\n'
full += edge('ev','anc','ANC ultrasound evidence')
(OUT/'raw_sources_to_reporting.dot').write_text(graph(full))
print('Wrote editable source-group and core diagrams.')
