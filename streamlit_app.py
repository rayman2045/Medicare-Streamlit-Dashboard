import streamlit as st
import plotly.express as px
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Medicare Part D Explorer", layout="wide")
session = get_active_session()

st.title("💊 Medicare Part D Prescribing Patterns (2019)")
st.caption("25.4M prescriber-drug records · CMS Part D Public Use File")

@st.cache_data
def q(sql):
    return session.sql(sql).to_pandas()

DB = "HEALTHCARE.MEDICARE"

# ---- Sidebar filter ----
states = q(f"SELECT STATE FROM {DB}.RPT_BY_STATE ORDER BY STATE")["STATE"].dropna().tolist()
sel = st.sidebar.multiselect("Filter by state", states)
state_filter = ""
if sel:
    inlist = ",".join("'" + s + "'" for s in sel)
    state_filter = f"WHERE STATE IN ({inlist})"

# ---- KPI row ----
#The k = q(...) line is the one that runs the SUM query and 
#stores the result; fmt then formats k.P, k.C, k.D. Without that line, k never exists — hence the error.

k = q(f"""SELECT SUM(PRESCRIBERS) P, SUM(TOTAL_CLAIMS) C, SUM(TOTAL_COST) D
          FROM {DB}.RPT_BY_STATE {state_filter}""").iloc[0]

# c1.metric("Prescribers", f"{k.P:,.0f}")
# c2.metric("Total Claims", f"{k.C:,.0f}")
# c3.metric("Total Drug Cost", f"${k.D:,.0f}")

def fmt(n):
    if n >= 1e9:  return f"{n/1e9:.1f}B"
    if n >= 1e6:  return f"{n/1e6:.1f}M"
    if n >= 1e3:  return f"{n/1e3:.1f}K"
    return f"{n:,.0f}"

c1, c2, c3 = st.columns(3)
c1.metric("Prescribers", fmt(k.P))
c2.metric("Total Claims", fmt(k.C))
c3.metric("Total Drug Cost", "$" + fmt(k.D))

# ---- Cost by state (map) ----
st.subheader("Total Drug Cost by State")
df_state = q(f"SELECT STATE, TOTAL_COST FROM {DB}.RPT_BY_STATE")
fig_map = px.choropleth(df_state, locations="STATE", locationmode="USA-states",
                        color="TOTAL_COST", scope="usa",
                        color_continuous_scale="Blues")
st.plotly_chart(fig_map, use_container_width=True)

# ---- Top drugs by cost ----
st.subheader("Top 15 Drugs by Total Cost")
df_drug = q(f"""SELECT DRUG, TOTAL_COST, TOTAL_CLAIMS
               FROM {DB}.RPT_BY_DRUG ORDER BY TOTAL_COST DESC LIMIT 15""")
fig_drug = px.bar(df_drug.sort_values("TOTAL_COST"),
                  x="TOTAL_COST", y="DRUG", orientation="h")
st.plotly_chart(fig_drug, use_container_width=True)

# ---- Top specialties by claims ----
st.subheader("Top 10 Prescriber Specialties by Claims")
df_spec = q(f"""SELECT SPECIALTY, TOTAL_CLAIMS, PRESCRIBERS
               FROM {DB}.RPT_BY_SPECIALTY ORDER BY TOTAL_CLAIMS DESC LIMIT 10""")
st.dataframe(df_spec, use_container_width=True, hide_index=True)

# ---- Cost vs claims scatter (drugs) ----
st.subheader("Cost vs. Claim Volume by Drug")
df_sc = q(f"""SELECT DRUG, TOTAL_CLAIMS, TOTAL_COST
             FROM {DB}.RPT_BY_DRUG WHERE TOTAL_CLAIMS > 1000
             ORDER BY TOTAL_COST DESC LIMIT 200""")
fig_sc = px.scatter(df_sc, x="TOTAL_CLAIMS", y="TOTAL_COST",
                    hover_name="DRUG", log_x=True, log_y=True)
st.plotly_chart(fig_sc, use_container_width=True)
